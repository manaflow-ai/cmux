// The host's one call into a document for chats' rows (design doc host contract; decision 277a):
// `window.cmuxChatRows.receive({batch, changes})`. Not a host event: it does not pass the page's
// router. A document builds more than one pane client over its life, each with its own host client
// and store, so the receiver is the document's: each change goes to the store that holds its sid,
// one the page holds in no store is dropped, and the batch is taken once, whatever the number.
import type { ChatRowsBatch, ChatRowsHost, ChatRowsPost } from "./host";
import { changeSid, parseChange, type ChatChange } from "./wire";

const hosts = new Set<ChatRowsHost>();
/// The post that answers `taken`, the document's: every pane client's is `postNative`. Kept after its
/// host leaves, so a batch the host built before it read that client's `chat.rows.close` is still taken;
/// the host sends no more changes until `taken` names the batch.
let takenPost: ChatRowsPost | undefined;

type ChatRowsGlobal = { cmuxChatRows?: { receive(event: ChatRowsBatch): void } };

/// Adds a host client to the document's receiver. The receiver itself is installed by
/// `listenForChatRows`, before the host's first `chat.rows.open`.
export function addChatRowsHost(host: ChatRowsHost, post: ChatRowsPost): void {
  hosts.add(host);
  takenPost = post;
}

/// Installs the document's receiver once, before a `chat.rows.open` is posted, so no batch comes with
/// nothing to take it. A document that never opens a chat on the store has no receiver.
export function listenForChatRows(): void {
  const scope = globalThis as ChatRowsGlobal;
  scope.cmuxChatRows ??= { receive: receiveChatRows };
}

/// Tests: the document's receiver taken away, as a new document starts.
export function resetChatRowsReceiver(): void {
  const scope = globalThis as ChatRowsGlobal;
  if (scope.cmuxChatRows?.receive === receiveChatRows) delete scope.cmuxChatRows;
  hosts.clear();
  takenPost = undefined;
}

/// A pane client the page dropped: its host takes no more changes.
export function removeChatRowsHost(host: ChatRowsHost): void {
  hosts.delete(host);
}

/// Routes a batch's changes to their stores and takes it once. Each store applies its own changes
/// even when another's throws; the first throw is rethrown after `taken` is posted.
export function receiveChatRows(event: ChatRowsBatch): void {
  const byHost = new Map<ChatRowsHost, ChatChange[]>();
  let failed: { error: unknown } | undefined;
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
    for (const [host, changes] of byHost)
      try {
        host.store.applyBatch(changes);
      } catch (error) {
        failed ??= { error };
      }
  } finally {
    if (takenPost) void takenPost("chat.rows.taken", { batch: event.batch }).catch(() => {});
  }
  if (failed) throw failed.error;
}
