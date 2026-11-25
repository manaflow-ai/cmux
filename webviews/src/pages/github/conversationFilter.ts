// The conversation's filters and order: everything, only review threads still open (each review
// keeps just its unresolved comments), or only what the signed-in person wrote; newest first by
// default, so a long review history opens on its latest word.
import type { ConversationEntry } from "./types";

export type ConversationFilter = "all" | "unresolved" | "mine";
export type ConversationOrder = "newest" | "oldest";

const unresolved = (entry: ConversationEntry) => entry.comments.filter((comment) => comment.resolved === false);

/** Whether `entry` was written by `viewer` (GitHub logins compare without case). */
export function mine(entry: ConversationEntry, viewer: string | undefined): boolean {
  return !!viewer && entry.author.toLowerCase() === viewer.toLowerCase();
}

/** How many entries each filter keeps. */
export function filterCounts(entries: readonly ConversationEntry[], viewer: string | undefined) {
  return {
    all: entries.length,
    unresolved: entries.filter((entry) => unresolved(entry).length > 0).length,
    mine: entries.filter((entry) => mine(entry, viewer)).length,
  };
}

/** `entries` through `filter`, in `order`; entries with the same time keep the read's order. */
export function filterConversation(
  entries: readonly ConversationEntry[],
  filter: ConversationFilter,
  order: ConversationOrder,
  viewer: string | undefined,
): ConversationEntry[] {
  let kept: ConversationEntry[];
  if (filter === "unresolved") {
    kept = entries.flatMap((entry) => {
      const open = unresolved(entry);
      return open.length ? [{ ...entry, comments: open }] : [];
    });
  } else if (filter === "mine") {
    kept = entries.filter((entry) => mine(entry, viewer));
  } else {
    kept = [...entries];
  }
  const time = (entry: ConversationEntry) => {
    const at = Date.parse(entry.at);
    return Number.isFinite(at) ? at : 0;
  };
  const indexed = kept.map((entry, index) => ({ entry, index }));
  indexed.sort((a, b) => {
    const delta = order === "newest" ? time(b.entry) - time(a.entry) : time(a.entry) - time(b.entry);
    return delta || a.index - b.index;
  });
  return indexed.map(({ entry }) => entry);
}
