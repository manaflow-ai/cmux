// A thread as an object: title, status (open or resolved) and owner, from the conversation
// owner's thread fields (conversation-thread-objects-v1: the root's `thread` object and the
// ThreadSummary fields). Every view reads a thread through `threadObject`; edits go through the
// store's `updateThread` (`thread.update`). Defaults: no title shows the root's first line, no
// owner is unowned, a new live reply after a resolution reopens the thread.
import { threadStatus, threadTitle } from "./model";
import type { HomeMessage, HomeThreadStats, HomeThreadStatus } from "./types";

export type ThreadStatus = HomeThreadStatus;

export interface ThreadObject {
  root: string;
  title: string;
  status: ThreadStatus;
  /** The participant who owns the thread; absent: unowned. */
  owner?: string;
}

/**
 * The thread object of `root`. `lastLiveSeq` is the newest loaded reply that is not retracted
 * (live events the stats have not counted). The owner's stats add their newest reply only while
 * they read the thread as open: a resolved summary's newest reply may be a retracted one after the
 * resolution, which does not reopen it.
 */
export function threadObject(
  root: HomeMessage,
  stats: HomeThreadStats | undefined,
  lastLiveSeq: number | undefined,
): ThreadObject {
  const object = root.thread ?? (stats ? summaryObject(stats) : undefined);
  const counted = stats && stats.status !== "resolved" ? stats.lastReplySeq : undefined;
  const newest = Math.max(lastLiveSeq ?? 0, counted ?? 0) || undefined;
  const owner = root.thread ? root.thread.owner : stats?.owner;
  return {
    root: root.id,
    title: object?.title || threadTitle(root),
    status: threadStatus(object, newest),
    ...(owner ? { owner } : {}),
  };
}

/** A root copy without its `thread` field (an older event copy): the summary's fields. */
function summaryObject(stats: HomeThreadStats): HomeMessage["thread"] {
  if (stats.status !== "resolved" && !stats.title && !stats.owner) return undefined;
  return {
    ...(stats.title ? { title: stats.title } : {}),
    ...(stats.owner ? { owner: stats.owner } : {}),
    // The summary says resolved as of its newest reply.
    ...(stats.status === "resolved"
      ? { resolved: { by: stats.resolvedBy ?? "", at: stats.resolvedAt ?? 0, seq: stats.lastReplySeq ?? 0 } }
      : {}),
  };
}

/** The newest loaded live reply of each thread root (pending sends and retracted replies excluded). */
export function lastLiveReplies(messages: readonly HomeMessage[], threadOf: (m: HomeMessage) => string | undefined) {
  const newest = new Map<string, number>();
  for (const message of messages) {
    const root = threadOf(message);
    if (!root || message.retracted || message.id.startsWith("pending:")) continue;
    newest.set(root, Math.max(newest.get(root) ?? 0, message.seq));
  }
  return newest;
}
