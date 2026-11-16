// The host's one call into a document for chats' rows (design doc host contract; decision 277a):
// `window.cmuxChatRows.receive({batch, changes})`. Not a host event: it does not pass the page's
// router. A document builds more than one pane client over its life, each with its own host client
// and store, so the receiver is the document's: each change goes to the store that holds its sid,
// one the page holds in no store is dropped, and the batch is taken once, whatever the number.
//
// Frame-paced (cmuxterm-hq docs/design/chat-instant-under-load.md, "Ingest is a queue, not a task"):
// `receive` only keeps the batch and returns. The frame lane applies it, in slices that break only
// between changes (a change, however big, is applied whole), giving way when a key is pending or the
// slice is spent, and answers `taken` once the batch's last change is applied and the stores'
// subscribers were told. The host sends nothing more until `taken`, so it is answered at most once a
// frame, and a hidden page (whose frame lane does not run) answers nothing until it is shown.
import { pageLanes, type Lanes, type Slice } from "../schedule";
import type { ChatRowsBatch, ChatRowsHost, ChatRowsPost } from "./host";
import { StorePart } from "./store";
import { changeSid, parseChange } from "./wire";

const hosts = new Set<ChatRowsHost>();
/// The post that answers `taken`, the document's: every pane client's is `postNative`. Kept after its
/// host leaves, so a batch the host built before it read that client's `chat.rows.close` is still taken;
/// the host sends no more changes until `taken` names the batch.
let takenPost: ChatRowsPost | undefined;
/// The lanes the document's receiver applies in; a test sets its own through `listenForChatRows`.
/// They live as long as the document: lanes disposed with a drain queued would drop it, and no
/// batch would be taken again until `resetChatRowsReceiver`.
let documentLanes: Lanes | undefined;

/// The frame lane's key for this work: one drain at a time, whatever the number of batches.
const FRAME_KEY = "chat-rows";

/// Batches received and not yet taken, oldest first. The host holds one batch until it is taken, so
/// this holds at most one in practice.
const pending: ChatRowsBatch[] = [];
/// The batch being applied: the next change's index, and each store's part of it so far. A change
/// goes to the store that holds its sid when it is applied, so a host dropped mid-batch (its sids
/// closed first) takes none of the rest.
let current: { batch: ChatRowsBatch; next: number; parts: Map<ChatRowsHost, StorePart> } | undefined;
/// A drain is queued in the frame lane or running there (it takes batches that come meanwhile).
let draining = false;
/// A store's first throw since the drain began; it may span slices.
let failed: { error: unknown } | undefined;

type ChatRowsGlobal = { cmuxChatRows?: { receive(event: ChatRowsBatch): void } };

/// Adds a host client to the document's receiver. The receiver itself is installed by
/// `listenForChatRows`, before the host's first `chat.rows.open`.
export function addChatRowsHost(host: ChatRowsHost, post: ChatRowsPost): void {
  hosts.add(host);
  takenPost = post;
}

/// Installs the document's receiver once, before a `chat.rows.open` is posted, so no batch comes with
/// nothing to take it. A document that never opens a chat on the store has no receiver. `lanes` is
/// for tests; the page's own lanes (`pageLanes()`) are made on the first batch.
export function listenForChatRows(lanes?: Lanes): void {
  if (lanes) documentLanes = lanes;
  const scope = globalThis as ChatRowsGlobal;
  scope.cmuxChatRows ??= { receive: receiveDocument };
}

function receiveDocument(event: ChatRowsBatch): void {
  receiveChatRows(event);
}

/// Tests: the document's receiver taken away, as a new document starts.
export function resetChatRowsReceiver(): void {
  const scope = globalThis as ChatRowsGlobal;
  if (scope.cmuxChatRows?.receive === receiveDocument) delete scope.cmuxChatRows;
  hosts.clear();
  takenPost = undefined;
  documentLanes = undefined;
  pending.length = 0;
  current = undefined;
  draining = false;
  failed = undefined;
}

/// A pane client the page dropped: its host takes no more changes.
export function removeChatRowsHost(host: ChatRowsHost): void {
  hosts.delete(host);
}

/// Keeps a batch for the frame lane and returns. Each store applies its own changes even when
/// another's throws; the first throw is reported after `taken` is posted.
export function receiveChatRows(event: ChatRowsBatch, lanes: Lanes = documentLanes ?? pageLanes()): void {
  pending.push(event);
  if (draining) return;
  draining = true;
  lanes.frame(FRAME_KEY, (slice) => drain(lanes, slice, 0));
}

/// Applies kept batches change by change. Returns a promise only when it gives the thread back, so a
/// drain that fits its slice runs in one go. `applied` counts the changes of this slice: at least one
/// is applied in each, so a key held down slows the batch to a change a frame and never stops it.
// perf-hot: 4ms chat-rows-frame-apply
function drain(lanes: Lanes, slice: Slice, applied: number): void | Promise<void> {
  for (;;) {
    if (!current) {
      const batch = pending.shift();
      if (!batch) break;
      current = { batch, next: 0, parts: new Map() };
    }
    const { batch, parts } = current;
    while (current.next < batch.changes.length) {
      if (applied > 0 && (slice.shouldYield() || lanes.inputPending())) {
        return lanes.yield().then(() => drain(lanes, slice, 0));
      }
      const line = batch.changes[current.next++];
      applied += 1;
      // Nothing one change does (a line that is not a change, a store that throws) may stop the
      // drain: the batch is still taken, or the host would wait on it for good.
      try {
        applyChange(line, parts);
      } catch (error) {
        failed ??= { error };
      }
    }
    current = undefined;
    for (const [host, part] of parts)
      try {
        host.store.commit(part);
      } catch (error) {
        failed ??= { error };
      }
    try {
      if (takenPost) void takenPost("chat.rows.taken", { batch: batch.batch }).catch(() => {});
    } catch (error) {
      failed ??= { error };
    }
  }
  draining = false;
  // Reported once every kept batch is applied and taken: a throw that stopped the drain would leave
  // the host waiting on `taken` for good.
  const error = failed;
  failed = undefined;
  if (error) throw error.error;
}

/// One change to the store that holds its sid now; one the page holds in no store is dropped.
function applyChange(line: unknown, parts: Map<ChatRowsHost, StorePart>): void {
  if (typeof line !== "string") return;
  const change = parseChange(line);
  const sid = change && changeSid(change);
  if (!change || sid === null) return;
  for (const host of hosts)
    if (host.store.has(sid)) {
      let part = parts.get(host);
      if (!part) parts.set(host, (part = new StorePart()));
      host.store.applyPart(part, [change]);
      return;
    }
}
