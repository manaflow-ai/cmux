// The host's one call into a document for chats' rows (design doc host contract; decision 277a):
// `window.cmuxChatRows.receive({batch, changes})`. Not a host event: it does not pass the page's
// router. A document builds more than one pane client over its life, each with its own host client
// and store, so the receiver is the document's: each change goes to the store that holds its sid,
// one the page holds in no store is dropped, and the batch is taken once, whatever the number.
import type { ChatRowsBatch, ChatRowsHost, ChatRowsPost } from "./host";
import { changeSid, parseChange, type ChatChange } from "./wire";

const hosts = new Set<ChatRowsHost>();
/// The post that answers `taken`: the newest host's (every pane client's is `postNative`).
const posts = new Map<ChatRowsHost, ChatRowsPost>();

type ChatRowsGlobal = { cmuxChatRows?: { receive(event: ChatRowsBatch): void } };

/// Adds a host client to the document's receiver, installing it once: before the host's first
/// `chat.rows.open`, so no batch comes with nothing to take it.
export function addChatRowsHost(host: ChatRowsHost, post: ChatRowsPost): void {
  hosts.add(host);
  posts.set(host, post);
  const scope = globalThis as ChatRowsGlobal;
  scope.cmuxChatRows ??= { receive: receiveChatRows };
}

/// A pane client the page dropped: its host takes no more batches.
export function removeChatRowsHost(host: ChatRowsHost): void {
  hosts.delete(host);
  posts.delete(host);
}

export function receiveChatRows(event: ChatRowsBatch): void {
  const byHost = new Map<ChatRowsHost, ChatChange[]>();
  try {
    for (const line of event.changes) {
      const change = parseChange(line);
      const sid = change && changeSid(change);
      if (!change || sid === null) continue;
      for (const host of hosts)
        if (host.store.has(sid)) {
          const mine = byHost.get(host);
          if (mine) mine.push(change);
          else byHost.set(host, [change]);
          break;
        }
    }
    for (const [host, changes] of byHost) host.store.applyBatch(changes);
  } finally {
    const post = [...posts.values()].at(-1);
    if (post) void post("chat.rows.taken", { batch: event.batch }).catch(() => {});
  }
}
