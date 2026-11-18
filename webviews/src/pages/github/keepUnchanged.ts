// The host answers with new objects every time (JSON over the page bridge), so a minute's refresh
// would hand every memoized row (a file, a check, a conversation entry) new props that say the same.
// These keep the previous object wherever the new one has the same content, and the previous array
// when nothing in it changed, so only a row whose own data changed draws again. Once per answer.
import type { ConversationEntry, LinkedPullRequest } from "./types";

/** Whether two JSON values say the same. */
export function sameValue(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a)) {
    const other = b as unknown[];
    return a.length === other.length && a.every((value, index) => sameValue(value, other[index]));
  }
  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length && keys.every((key) => sameValue(left[key], right[key]));
}

/** `next` with each item that says the same as the previous item of its key kept as that one; the
 *  previous array itself when every item is kept in the same order. */
export function keepUnchanged<T>(
  previous: readonly T[] | undefined,
  next: readonly T[],
  key: (item: T, index: number) => string,
): readonly T[] {
  if (!previous) return next;
  const held = new Map(previous.map((item, index) => [key(item, index), item]));
  const kept = next.map((item, index) => {
    const old = held.get(key(item, index));
    return old !== undefined && sameValue(old, item) ? old : item;
  });
  return kept.length === previous.length && kept.every((item, index) => item === previous[index]) ? previous : kept;
}

/** A pull request's new answer with its files and checks kept where they did not change. */
export function keepPullRequest(previous: LinkedPullRequest | undefined, next: LinkedPullRequest): LinkedPullRequest {
  if (!previous || previous.url !== next.url) return next;
  const files = next.files && keepUnchanged(previous.files, next.files, (file) => file.path);
  const checkList = next.checkList && keepUnchanged(previous.checkList, next.checkList, (check) => check.name);
  return files === next.files && checkList === next.checkList ? next : { ...next, files, checkList };
}

/** A conversation's new read with its unchanged entries kept (an entry is keyed by its link). */
export function keepConversation(
  previous: readonly ConversationEntry[] | undefined,
  next: ConversationEntry[],
): ConversationEntry[] {
  return keepUnchanged(previous, next, (entry, index) => entry.url ?? `#${index}`) as ConversationEntry[];
}
