// Nested threads in the thread view (a port of MessagesLab's ThreadTree in tree mode,
// Vendor/catalyst/ThreadHost.swift, and HomeProjection+Tree): the open thread shows the root and
// its whole tree, or one drilled branch (a reply and everything under it). "N Replies" under a
// shown reply with replies of its own drills into its branch; Back steps out one level. A reply
// whose parent is not loaded hangs under the root, as `threadTree` places it.
import { threadOf, threadTree } from "../../home-channels/model";
import type { HomeMessage } from "../../home-channels/types";

/** The drill path from the root down to `id` (outermost first, `id` last) through the loaded
 * parents; `[]` for the root itself or a message outside the thread. */
export function threadPath(id: string, root: string, messages: readonly HomeMessage[]): string[] {
  if (id === root) return [];
  const replies = messages.filter((message) => threadOf(message) === root);
  const byId = new Map(threadTree(replies, root).map((entry) => [entry.message.id, entry]));
  const node = byId.get(id);
  if (!node) return [];
  const path = [id];
  const seen = new Set(path);
  let parent = node.parent;
  while (parent && !seen.has(parent.id)) {
    path.push(parent.id);
    seen.add(parent.id);
    parent = byId.get(parent.id)?.parent;
  }
  return path.reverse();
}

/** What the thread view shows for `path` (drilled reply ids below the root): the messages in tree
 * order (the root first, or the branch's top first) and the "N Replies" counts under them (each
 * message's live replies below it, at any depth; none on the root or the branch's top). A path
 * whose last reply is not loaded shows the whole thread. */
export function threadBranch(
  messages: readonly HomeMessage[],
  root: string,
  path: readonly string[],
): { messages: HomeMessage[]; counts: Map<string, number>; top: string } {
  const rootMessage = messages.find((message) => message.id === root);
  const replies = messages.filter((message) => threadOf(message) === root);
  const nodes = threadTree(replies, root);
  // Every live reply counts once for each of its ancestors (reverse tree order: children first).
  const counts = new Map<string, number>();
  for (let index = nodes.length - 1; index >= 0; index -= 1) {
    const node = nodes[index]!;
    const below = (counts.get(node.message.id) ?? 0) + (node.message.retracted ? 0 : 1);
    if (node.parent) counts.set(node.parent.id, (counts.get(node.parent.id) ?? 0) + below);
  }
  const last = path.at(-1);
  const at = last === undefined ? -1 : nodes.findIndex((node) => node.message.id === last);
  let shown: HomeMessage[];
  let top = root;
  if (at >= 0) {
    const depth = nodes[at]!.depth;
    let end = at + 1;
    while (end < nodes.length && nodes[end]!.depth > depth) end += 1;
    shown = nodes.slice(at, end).map((node) => node.message);
    top = nodes[at]!.message.id;
  } else {
    shown = [...(rootMessage ? [rootMessage] : []), ...nodes.map((node) => node.message)];
  }
  counts.delete(root);
  counts.delete(top);
  return { messages: shown, counts, top };
}
