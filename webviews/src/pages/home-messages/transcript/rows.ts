// The Messages transcript's rows, derived from the conversation's data (a port of MessagesLab's
// `RowBuilder.rows` and `receiptTargets`, Packages/Shared/CmuxMessagesLab/.../Vendor/catalyst/Layout.swift,
// with HomeMapping's delivery status). Pure: the same data and clock give the same rows, so the
// window can lay them out from estimates and a send moves only what is below the change.
//
// The rules, as the Swift transcript has them:
// - A time label (day bold, then the time) heads the first message and any message more than an
//   hour after the one above it (macOS 27's Messages).
// - A group is one sender's messages less than a minute apart, in one thread; the last bubble of a
//   group has the tail. In a group chat another person's run gets their name over its first bubble
//   and their avatar beside its last.
// - "Read" (with its time) goes under my newest message another participant has read; "Delivered"
//   under my newest committed message after it. A failed send says "Not Delivered".
// - Others typing show one typing bubble at the end; a participant whose reply is streaming shows
//   that reply as its bubble instead.
// - Gaps are Messages' measured ones (points, drawn as CSS pixels).
import { PENDING_PREFIX, pendingMessages, threadOf } from "../../home-channels/model";
import type { HomeDraft } from "../../home-channels/drafts";
import type { PendingSend } from "../../home-channels/store";
import type { HomeConversation, HomeMessage, HomeParticipant, HomePart, HomeReaction } from "../../home-channels/types";

/** Messages under a minute apart from one sender in one thread are one group (`RowBuilder.groupGap`). */
export const GROUP_GAP_MS = 60_000;
/** A time label heads a message more than an hour after the one above (`RowBuilder.separatorGap`, macOS 27). */
export const SEPARATOR_GAP_MS = 60 * 60_000;

/** Another participant's read cursor: the newest seq they read, and when. */
export interface ReadCursor {
  seq: number;
  at: number;
}

/** My message's delivery: sending (pending), failed (pending, the owner refused or never answered),
 * delivered (committed) or read (another participant's read cursor reached it). */
export type Delivery =
  | { state: "sending" }
  | { state: "failed" }
  | { state: "delivered" }
  | { state: "read"; at: number };

/** What the rows derive from (the view reads only these). */
export interface TranscriptData {
  me: string;
  conversation: HomeConversation;
  /** Confirmed messages, ascending by seq. */
  messages: readonly HomeMessage[];
  /** My sends the owner has not shown yet (the store's intent log), oldest first. */
  pending?: readonly PendingSend[];
  /** The other participants' read cursors, by participant id. */
  readCursors?: Readonly<Record<string, ReadCursor>>;
  /** Participant ids typing in the conversation. */
  typing?: readonly string[];
  /** A participant's running reply (`conversation-draft`), drawn as their bubble. */
  draft?: HomeDraft;
  /** Older messages exist before the first one: the top row loads them. */
  hasOlder?: boolean;
  loadingOlder?: boolean;
}

interface RowBase {
  key: string;
  /** Space above the row (CSS px), part of its measured height. */
  gap: number;
}

export type TranscriptRow =
  | (RowBase & { kind: "older"; loading: boolean })
  | (RowBase & { kind: "separator"; at: number })
  | (RowBase & { kind: "name"; participant: HomeParticipant })
  | (RowBase & {
      kind: "bubble";
      message: HomeMessage;
      /** One text-like part, or a run of attachment parts. */
      parts: readonly HomePart[];
      partIndex: number;
      outgoing: boolean;
      tail: boolean;
      /** A group chat's other person: their avatar beside this, the last bubble of their run. */
      avatar?: HomeParticipant;
      /** A group chat's other person: the bubble sits right of the avatar column. */
      indent: boolean;
      delivery?: Delivery;
      reactions: readonly HomeReaction[];
      /** The author is an agent: the text is Markdown (code, tables, diagrams). */
      markdown: boolean;
      /** A running reply, still growing. */
      streaming?: boolean;
    })
  | (RowBase & { kind: "label"; outgoing: boolean; label: "edited" | "notDelivered" })
  | (RowBase & { kind: "unsent"; outgoing: boolean })
  | (RowBase & { kind: "receipt"; receipt: "read" | "delivered"; at?: number })
  | (RowBase & { kind: "typing"; participants: readonly string[] });

/** The id prefix of a running reply's message. */
export const STREAM_PREFIX = "stream:";

const isTextLike = (part: HomePart) => part.type !== "attachment";

/** The other participants' read cursors, by id (HomeMapping reads the first reader by id). */
export function readersOf(readCursors: Readonly<Record<string, ReadCursor>> | undefined, me: string) {
  return Object.entries(readCursors ?? {})
    .filter(([id]) => id !== me)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([id, cursor]) => ({ id, ...cursor }));
}

/** My message's delivery (HomeMapping `status`): undefined for others' messages. */
export function deliveryOf(
  message: HomeMessage,
  me: string,
  failed: ReadonlySet<string>,
  readers: readonly { id: string; seq: number; at: number }[],
): Delivery | undefined {
  if (message.author !== me) return undefined;
  if (message.id.startsWith(PENDING_PREFIX))
    return failed.has(message.id.slice(PENDING_PREFIX.length)) ? { state: "failed" } : { state: "sending" };
  const reader = readers.find((cursor) => cursor.seq >= message.seq);
  return reader ? { state: "read", at: reader.at } : { state: "delivered" };
}

/** Which of my messages carry a receipt (`receiptTargets`): my newest read one, and my newest delivered
 * one when it is newer. From the newest back to the newest read one: O(tail), not O(window). */
export function receiptTargets(
  messages: readonly HomeMessage[],
  deliveries: ReadonlyMap<string, Delivery>,
): Map<string, { receipt: "read" | "delivered"; at?: number }> {
  let read: { index: number; id: string; at: number } | undefined;
  let delivered: { index: number; id: string } | undefined;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index]!;
    if (message.retracted) continue;
    const delivery = deliveries.get(message.id);
    if (!delivery) continue;
    if (delivery.state === "read") {
      read = { index, id: message.id, at: delivery.at };
      break;
    }
    if (delivery.state === "delivered" && !delivered) delivered = { index, id: message.id };
  }
  const out = new Map<string, { receipt: "read" | "delivered"; at?: number }>();
  if (read) out.set(read.id, { receipt: "read", at: read.at });
  if (delivered && delivered.index > (read?.index ?? -1)) out.set(delivered.id, { receipt: "delivered" });
  return out;
}

/** The transcript's messages in order: the confirmed ones, my pending sends after them, then a running reply. */
export function orderedMessages(data: TranscriptData, now: number): HomeMessage[] {
  const last = data.messages.at(-1)?.seq ?? 0;
  const pending = pendingMessages(data.pending ?? [], data.conversation.id, data.me, last);
  const all = pending.length ? [...data.messages, ...pending] : [...data.messages];
  if (data.draft?.text) {
    all.push({
      id: `${STREAM_PREFIX}${data.draft.turn}`,
      conversation: data.conversation.id,
      seq: last + pending.length + 1,
      author: data.draft.participant,
      createdAt: now,
      retracted: false,
      parts: [{ type: "text", text: data.draft.text, mentions: [] }],
      reactions: [],
    });
  }
  return all;
}

/** Rows already derived, per message: a message whose inputs did not change (itself, its neighbours,
 * its delivery and receipt, its thread, the row above it) keeps its rows, so a send, a typing change
 * or a receipt that moves re-derives only the messages around the change. View state only. */
export class RowCache {
  private entries = new WeakMap<HomeMessage, { inputs: RowInputs; rows: TranscriptRow[] }>();
  private context?: string;

  /** The cache for this conversation and cast (by value: an inbox refresh's new objects keep it);
   * another conversation, or a name or kind change, starts it over. */
  use(me: string, conversation: HomeConversation): this {
    const people = conversation.participants.map((person) => `${person.id}\u0000${person.name}\u0000${person.kind}`);
    const context = [me, conversation.id, conversation.kind, ...people].join("\u0001");
    if (context !== this.context) {
      this.entries = new WeakMap();
      this.context = context;
    }
    return this;
  }

  get(message: HomeMessage, inputs: RowInputs): TranscriptRow[] | undefined {
    const entry = this.entries.get(message);
    if (!entry) return undefined;
    const kept = entry.inputs;
    for (const key of INPUT_KEYS) if (kept[key] !== inputs[key]) return undefined;
    return entry.rows;
  }

  set(message: HomeMessage, inputs: RowInputs, rows: TranscriptRow[]): void {
    this.entries.set(message, { inputs, rows });
  }
}

/** What one message's rows depend on besides the message itself. */
interface RowInputs {
  prev?: HomeMessage;
  next?: HomeMessage;
  above?: TranscriptRow["kind"];
  delivery?: Delivery["state"];
  readAt?: number;
  receipt?: "read" | "delivered";
  receiptAt?: number;
  threadPrev?: string;
  threadSelf?: string;
  threadNext?: string;
}

const INPUT_KEYS = [
  "prev",
  "next",
  "above",
  "delivery",
  "readAt",
  "receipt",
  "receiptAt",
  "threadPrev",
  "threadSelf",
  "threadNext",
] as const satisfies readonly (keyof RowInputs)[];

/** The rows of the conversation (`RowBuilder.rows`). `now` names the day labels (Today, Yesterday).
 * With `cache`, unchanged messages keep their rows (the same objects). */
export function transcriptRows(data: TranscriptData, now: number, cache?: RowCache): TranscriptRow[] {
  const { me, conversation } = data;
  cache?.use(me, conversation);
  const people = new Map(conversation.participants.map((person) => [person.id, person]));
  const group = conversation.kind === "group";
  const messages = orderedMessages(data, now);
  const failed = new Set((data.pending ?? []).filter((entry) => entry.failed).map((entry) => entry.key));
  const readers = readersOf(data.readCursors, me);
  const deliveries = new Map<string, Delivery>();
  for (const message of messages) {
    if (message.author !== me) continue;
    const delivery = deliveryOf(message, me, failed, readers);
    if (delivery) deliveries.set(message.id, delivery);
  }
  const receipts = receiptTargets(messages, deliveries);
  // A message with a live reply is its thread's root.
  const liveRoots = new Set<string>();
  for (const message of messages) {
    const root = threadOf(message);
    if (root && !message.retracted) liveRoots.add(root);
  }
  const thread = (message: HomeMessage | undefined) =>
    message ? (threadOf(message) ?? (liveRoots.has(message.id) ? message.id : undefined)) : undefined;
  const sameRun = (a: HomeMessage, b: HomeMessage) =>
    a.author === b.author &&
    Math.abs(b.createdAt - a.createdAt) < GROUP_GAP_MS &&
    !a.retracted &&
    !b.retracted &&
    thread(a) === thread(b);

  const rows: TranscriptRow[] = [];
  if (data.hasOlder) rows.push({ kind: "older", key: "older", gap: 0, loading: data.loadingOlder === true });
  let prev: HomeMessage | undefined;
  for (let index = 0; index < messages.length; index += 1) {
    const message = messages[index]!;
    const next = messages[index + 1];
    const last = rows.at(-1)?.kind;
    const delivery = deliveries.get(message.id);
    const receipt = receipts.get(message.id);
    const inputs: RowInputs = {
      prev,
      next,
      above: last,
      delivery: delivery?.state,
      readAt: delivery?.state === "read" ? delivery.at : undefined,
      receipt: receipt?.receipt,
      receiptAt: receipt?.at,
      threadPrev: thread(prev),
      threadSelf: thread(message),
      threadNext: thread(next),
    };
    const kept = cache?.get(message, inputs);
    if (kept) {
      for (const row of kept) rows.push(row);
      prev = message;
      continue;
    }
    const own: TranscriptRow[] = [];
    const outgoing = message.author === me;
    let gap: number;
    if (!prev || message.createdAt - prev.createdAt > SEPARATOR_GAP_MS) {
      own.push({ kind: "separator", key: `sep:${message.id}`, gap: prev ? 0 : 12, at: message.createdAt });
      gap = 0;
    } else if (threadOf(message) && threadOf(message) === prev.id) {
      // Right under its root: 2.5 under the bubble, 4 under a receipt, 3.5 under a label.
      gap = last === "bubble" ? 2.5 : last === "receipt" ? 4 : 3.5;
    } else if (thread(prev) !== thread(message)) {
      gap = 32;
    } else if (prev.author === message.author && message.createdAt - prev.createdAt < GROUP_GAP_MS) {
      gap = 3;
    } else if (prev.author === message.author && thread(message)) {
      gap = 32;
    } else {
      gap = 8;
    }
    // Under a receipt the receipt row takes the place of the gap: the next bubble sits 4 under it.
    if (own.length === 0 && last === "receipt" && gap > 4) gap = 4;

    if (message.retracted) {
      own.push({ kind: "unsent", key: `unsent:${message.id}`, gap: Math.max(gap, 8), outgoing });
    } else {
      const lastOfGroup = !next || !sameRun(message, next);
      const startsRun = !prev || !sameRun(prev, message);
      const inGroup = group && !outgoing;
      const sender = inGroup ? people.get(message.author) : undefined;
      if (sender?.name && startsRun) {
        own.push({ kind: "name", key: `name:${message.id}`, gap, participant: sender });
        gap = 1;
      }
      // Text parts are a bubble each; a run of attachments is one row of media.
      const chunks: { index: number; parts: HomePart[] }[] = [];
      message.parts.forEach((part, partIndex) => {
        const open = chunks.at(-1);
        if (!isTextLike(part) && open && !isTextLike(open.parts[0]!)) open.parts.push(part);
        else chunks.push({ index: partIndex, parts: [part] });
      });
      const markdown = people.get(message.author)?.kind === "agent";
      chunks.forEach((chunk, chunkIndex) => {
        const end = chunk.index + chunk.parts.length;
        const reactions = message.reactions.length
          ? message.reactions.filter((reaction) => reaction.partIndex >= chunk.index && reaction.partIndex < end)
          : message.reactions;
        let partGap = chunkIndex === 0 ? gap : 3;
        // A tapback badge takes 27.5 over its part (a thread change above it is 5 less).
        if (reactions.length) partGap = (partGap >= 32 ? partGap - 5 : partGap) + 27.5;
        const final = chunkIndex === chunks.length - 1;
        own.push({
          kind: "bubble",
          key: `part:${message.id}:${chunk.index}`,
          gap: partGap,
          message,
          parts: chunk.parts,
          partIndex: chunk.index,
          outgoing,
          tail: lastOfGroup && final,
          avatar: inGroup && lastOfGroup && final ? sender : undefined,
          indent: inGroup,
          delivery,
          reactions,
          markdown,
          streaming: message.id.startsWith(STREAM_PREFIX) || undefined,
        });
      });
      if (message.editedAt) own.push({ kind: "label", key: `edited:${message.id}`, gap: 1, outgoing, label: "edited" });
      if (delivery?.state === "failed")
        own.push({ kind: "label", key: `failed:${message.id}`, gap: 1, outgoing, label: "notDelivered" });
      if (receipt) own.push({ kind: "receipt", key: `receipt:${message.id}`, gap: 0, ...receipt });
    }
    cache?.set(message, inputs, own);
    for (const row of own) rows.push(row);
    prev = message;
  }
  // Others typing, without anyone whose reply already shows as its bubble.
  const writer = data.draft?.text ? data.draft.participant : undefined;
  const typists = (data.typing ?? []).filter((id) => id !== me && id !== writer);
  if (typists.length) {
    const last = rows.at(-1)?.kind;
    rows.push({
      kind: "typing",
      key: "typing",
      gap: last === "bubble" || last === "unsent" ? 14 : 0,
      participants: typists,
    });
  }
  return rows;
}

/** A row's height before it is measured (its gap included): the window lays out from these. */
export function estimateRow(row: TranscriptRow): number {
  switch (row.kind) {
    case "older":
      return 28;
    case "separator":
      return row.gap + 32;
    case "name":
      return row.gap + 15;
    case "label":
      return row.gap + 15;
    case "unsent":
      return row.gap + 16;
    case "receipt":
      return 16;
    case "typing":
      return row.gap + 35;
    case "bubble": {
      const part = row.parts[0];
      if (part?.type === "attachment") return row.gap + 160 * Math.min(row.parts.length, 2);
      const text = part && "text" in part ? part.text : "";
      const lines = text.split("\n").reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / 48)), 0);
      return row.gap + 16 + 18 * Math.min(lines, 400);
    }
  }
}

/** The participant ids the typing row names, as the a11y line reads them. */
export function typingNames(participants: readonly string[], people: ReadonlyMap<string, HomeParticipant>): string[] {
  return participants.map((id) => people.get(id)?.name ?? id);
}
