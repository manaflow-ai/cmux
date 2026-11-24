import { createContext } from "react";
import type { IncomingMessage } from "./incomingMessage";
import type { InboxThread } from "./inboxNotice";
import { senderName } from "./senderIdentity";

/// How the hover lays its messages out. `threads`, the default: each sender once, newest first,
/// with its count and its newest message whole. `digest`: the newest message whole, then the other
/// senders' names with their counts. `messages`: each message's sender, then two lines of it, five
/// at most. `lines`: one line each, "sender  first line". `names`: the senders only, each once,
/// with their marks (the list it was, without the noise).
export type GroupHoverLook = "threads" | "digest" | "messages" | "lines" | "names";
export const GroupHoverLookContext = createContext<GroupHoverLook>("threads");

/// A sender's short name: the part after its machine ("gcp-agent-lane-1/ux-owner" reads "ux-owner").
export const shortSender = (name: string) => senderName(name).split("/").at(-1)?.trim() || senderName(name);

/// What a group's hover lists: its messages, newest first, and how many messages the group holds in
/// all, so "+N more" counts the true rest (a thread that held only its preview is one line for its
/// whole count). `counts[i]`, when given, is how many messages `messages[i]` stands for (one when
/// not given), so the digest counts each sender's true share.
export type GroupHoverList = { messages: readonly IncomingMessage[]; total: number; counts?: readonly number[] };

/// A group's hover from its members, oldest first; `counts[i]` is how many messages member i stands
/// for (a preview-only inbox delivery stands for its thread's count), one when not given; `ats[i]`
/// is member i's row time. Newest first by when each message came (its own `at`, an inbox
/// message's, else its row's), never by the members' order alone: an inbox notice lists its
/// threads in its own order. A tie, or a member with no time, keeps the later member first.
export function hoverMessages(
  messages: readonly (IncomingMessage | undefined)[],
  counts: readonly (number | undefined)[] = [],
  ats: readonly (number | undefined)[] = [],
): GroupHoverList {
  const listed: { message: IncomingMessage; at?: number; order: number; count: number }[] = [];
  let total = 0;
  messages.forEach((message, index) => {
    if (!message) return;
    const at = message.at ?? ats[index];
    const count = Math.max(1, counts[index] ?? 1);
    listed.push({ message, ...(at !== undefined && { at }), order: index, count });
    total += count;
  });
  listed.sort((a, b) =>
    a.at !== undefined && b.at !== undefined ? b.at - a.at || b.order - a.order : b.order - a.order,
  );
  return { messages: listed.map((entry) => entry.message), total, counts: listed.map((entry) => entry.count) };
}

/// An inbox notice's hover: every message of every thread, newest first by when acpmux recorded it
/// (`at`), then the untimed ones by the notice's order, the later first; a thread that held only its preview is one line that counts
/// the thread's whole count (Leo, 2026-11-07, on a "Received 7 messages" hover that listed one).
export function inboxHover(threads: readonly InboxThread[]): GroupHoverList {
  const entries: { message: IncomingMessage; at?: number; order: number; count: number }[] = [];
  let total = 0;
  for (const thread of threads) {
    const newest = thread.messages?.at(-1)?.from || thread.from.at(-1) || "";
    const session = thread.fromSession ?? thread.sender?.session;
    const sent = (name: string) => ({
      name,
      raw: "",
      // The thread's session and family are its newest sender's: another sender's are its own.
      ...(name === newest && session && { sessionId: session }),
      ...(name === newest && thread.fromHarness && { harness: thread.fromHarness }),
    });
    if (thread.messages?.length) {
      for (const message of thread.messages) {
        const own = message.sender?.session;
        entries.push({
          message: {
            ...sent(message.from || newest),
            text: message.text,
            ...(own && { sessionId: own }),
            ...(message.harness && { harness: message.harness }),
            ...(message.unverified && { unverified: true as const }),
          },
          ...(message.at !== undefined && { at: message.at }),
          order: entries.length,
          count: 1,
        });
      }
      total += Math.max(thread.count, thread.messages.length);
    } else {
      entries.push({
        message: { ...sent(newest), text: thread.preview, ...(thread.unverified && { unverified: true as const }) },
        order: entries.length,
        count: Math.max(1, thread.count),
      });
      total += Math.max(1, thread.count);
    }
  }
  // Newest first: the messages acpmux timed by their time (a tie, the later in the notice first),
  // then those it did not (a thread's preview), the later in the notice first.
  entries.sort((a, b) => {
    if (a.at !== undefined && b.at !== undefined) return b.at - a.at || b.order - a.order;
    if (a.at !== undefined) return -1;
    if (b.at !== undefined) return 1;
    return b.order - a.order;
  });
  return { messages: entries.map((entry) => entry.message), total, counts: entries.map((entry) => entry.count) };
}

/// The digest's other senders: each once, newest first, with how many messages they sent; the
/// newest sender's earlier messages count under their own name.
export function hoverSenders(list: GroupHoverList): { message: IncomingMessage; count: number; unverified: boolean }[] {
  const [newest, ...others] = list.messages;
  if (!newest) return [];
  const senders: { message: IncomingMessage; count: number; unverified: boolean }[] = [];
  const index = new Map<string, number>();
  const add = (message: IncomingMessage, count: number) => {
    const key = senderName(message.name);
    const at = index.get(key);
    if (at === undefined) {
      index.set(key, senders.length);
      senders.push({ message, count, unverified: message.unverified === true });
      return;
    }
    const sender = senders[at]!;
    sender.count += count;
    sender.unverified ||= message.unverified === true;
  };
  // A newest line that stands for several (a thread that held only its preview): the rest are that
  // sender's earlier messages.
  const newestRest = Math.max(1, list.counts?.[0] ?? 1) - 1;
  if (newestRest > 0) add(newest, newestRest);
  others.forEach((message, offset) => add(message, Math.max(1, list.counts?.[offset + 1] ?? 1)));
  return senders;
}

/// The threads look's senders: each once, newest first (by its newest message), with its newest
/// message and how many messages it sent in all.
export function hoverThreads(list: GroupHoverList): { message: IncomingMessage; count: number; unverified: boolean }[] {
  const threads: { message: IncomingMessage; count: number; unverified: boolean }[] = [];
  const index = new Map<string, number>();
  list.messages.forEach((message, at) => {
    const count = Math.max(1, list.counts?.[at] ?? 1);
    const key = senderName(message.name);
    const seen = index.get(key);
    if (seen === undefined) {
      index.set(key, threads.length);
      threads.push({ message, count, unverified: message.unverified === true });
      return;
    }
    const thread = threads[seen]!;
    thread.count += count;
    thread.unverified ||= message.unverified === true;
  });
  return threads;
}
