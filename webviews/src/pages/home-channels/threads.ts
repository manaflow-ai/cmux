// Threads as objects: a thread is a unit of work with a title, a status (open or resolved) and an
// owner. Every thread object the page shows comes from `workThread` below, the one place that
// decides them. Today the owner's records carry no thread fields yet, so `workThread` derives them:
// the title is the root's first line, the owner is the root's author, the status is open, and a
// person's change (resolve, reopen, a new owner) is kept in page memory (`ThreadEdits`) until the
// owner stores thread fields. When it does, only this file and the store's two edit calls change.
import { messageText, type ThreadSummary } from "./model";
import type { HomeMessage, HomeThreadStats } from "./types";

export type ThreadStatus = "open" | "resolved";

/** A person's edits of one thread, kept by the page until the owner stores thread fields. */
export interface ThreadEdit {
  status?: ThreadStatus;
  owner?: string;
}
export type ThreadEdits = ReadonlyMap<string, ThreadEdit>;

export interface WorkThread {
  /** The root message's id (the thread's id and its link target). */
  id: string;
  root: HomeMessage;
  title: string;
  status: ThreadStatus;
  /** Participant id. */
  owner: string;
  replyCount: number;
  /** The newest activity: the last reply, else the root. */
  lastAt: number;
  /** Reply authors (first three distinct). */
  authors: string[];
  /** Replies after my read cursor when the conversation opened. */
  unread: number;
}

const TITLE_MAX = 90;

/** A thread title from its root: the first non-empty line, without Markdown marks. */
export function threadTitle(root: HomeMessage): string {
  const line =
    messageText(root)
      .split("\n")
      .map((text) => text.trim())
      .find((text) => text.length > 0) ?? "";
  const plain = line
    .replace(/^#{1,6}\s+|^>\s+|^[-*+]\s+|^\d+\.\s+/, "")
    .replace(/\*\*|__|~~|`/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1");
  // The first sentence when it is long enough to name the work.
  const sentence = /^(.{24,}?[.!?])\s/.exec(plain)?.[1] ?? plain;
  return sentence.length > TITLE_MAX ? `${sentence.slice(0, TITLE_MAX - 1).trimEnd()}…` : sentence;
}

/** THE thread object of one root (see the file comment). */
export function workThread(root: HomeMessage, summary: ThreadSummary | undefined, edit: ThreadEdit | undefined): WorkThread {
  return {
    id: root.id,
    root,
    title: threadTitle(root),
    status: edit?.status ?? "open",
    owner: edit?.owner ?? root.author,
    replyCount: summary?.count ?? 0,
    lastAt: Math.max(root.createdAt, summary?.lastAt ?? 0),
    authors: summary?.authors ?? [],
    unread: summary?.unread ?? 0,
  };
}

/** The conversation's threads: every top-level message with replies, or one a person edited. Newest
 * activity first. */
export function workThreads(
  messages: readonly HomeMessage[],
  summaries: ReadonlyMap<string, ThreadSummary>,
  edits: ThreadEdits,
): WorkThread[] {
  const list: WorkThread[] = [];
  for (const message of messages) {
    if (message.threadRoot && message.threadRoot !== message.id) continue;
    if (message.replyTo) continue;
    const summary = summaries.get(message.id);
    const edit = edits.get(message.id);
    if (!summary && !edit) continue;
    list.push(workThread(message, summary, edit));
  }
  return list.sort((a, b) => b.lastAt - a.lastAt);
}

/** What the conversation list shows of a conversation's threads without opening it: the roots the
 * page has read (a page of the conversation, its events) with the owner's reply counts. */
export interface ThreadIndexEntry {
  root: string;
  author: string;
  replyCount: number;
  lastAt: number;
}

export function indexEntries(messages: readonly HomeMessage[], stats: readonly HomeThreadStats[] | undefined): ThreadIndexEntry[] {
  const byId = new Map(messages.map((m) => [m.id, m]));
  return (stats ?? [])
    .filter((entry) => entry.replyCount > 0)
    .map((entry) => {
      const root = byId.get(entry.root);
      return {
        root: entry.root,
        author: root?.author ?? "",
        replyCount: entry.replyCount,
        lastAt: entry.lastReplyAt ?? root?.createdAt ?? 0,
      };
    });
}

export type ThreadFilter = "all" | "mine" | "chiefs";
