// The page's side of the host contract for a chat's rows (decision 224): five operations under
// `cmux.agent.chat.rows.*` and one event, `{batch, changes}`, which the host passes to a receiver
// the page installs (decision 227). Each change string is one change as the client core gave it;
// this decodes them, hands the batch to the store and answers `taken` at once, so the host sends
// the next. It holds at most the batch it is applying, and queues nothing behind a render: a page
// that stalls costs the daemon's credit, not this page memory.
//
// No order is promised between an operation's answer and the event (decision 228), so the page
// names each sid and blob id itself and the store holds it before the operation is posted: a
// change that comes before the answer is applied, never dropped.
import { ChatRowStore, type BlobTarget, type ChatAnchor } from "./store";
import { parseChange, type ChatChange } from "./wire";

/// The host's `postNative`, injected so a test (and the browser dev slot) can give its own.
export type ChatRowsPost = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export type ChatRowsBatch = { batch: number; changes: readonly string[] };

/// What `open` gives: the sid the page named, or the code the chat falls to v1 with.
export type ChatRowsOpen = { sid: string } | { fallen: string };

/// Names for sids and blob ids (decision 228): a prefix made once per document from 64 random
/// bits, then a counter, `<prefix>.<n>`. Hex and digits only, so always in `A-Za-z0-9._-` and far
/// under 64 bytes. A reloaded page gets a new prefix, so a frame on its way for the old document's
/// sub matches nothing.
export function chatRowsNamer(): () => string {
  const bits = new Uint32Array(2);
  crypto.getRandomValues(bits);
  const prefix = Array.from(bits, (word) => word.toString(16).padStart(8, "0")).join("");
  let next = 0;
  return () => `${prefix}.${++next}`;
}

/// A host that says it has no such operation is `off` for the document (decision 277b): the page
/// host's `cmux.protocol.unknown_op`, or the old bridge's `unsupported` (the five operations live
/// in the page host's `cmux.agent.` namespace only).
export const CHAT_ROWS_OFF = "chat.rows.off";
/// The page's own code for an open the host did not answer within `OPEN_ANSWER_MS`: that chat
/// falls to v1 this once; the next open of it asks again.
export const CHAT_ROWS_LATE = "chat.rows.late";
/// The page's own code for an open refused with no code (a lost link, decision 277c): that chat
/// falls to v1 this once; the next open of it asks again.
export const CHAT_ROWS_LOST = "chat.rows.lost";
/// The longest a switch waits on the host's answer to an open (decision 276 e). `postNative` has
/// no deadline of its own, so this is the one timer.
export const OPEN_ANSWER_MS = 250;

function refusalCode(error: unknown): string {
  const known = error as { code?: unknown; details?: { protocol?: unknown } } | null;
  if (known?.details?.protocol === "cmux.protocol.unknown_op" || known?.code === "unsupported") return CHAT_ROWS_OFF;
  if (typeof known?.code === "string" && known.code) return known.code;
  return CHAT_ROWS_LOST;
}

export class ChatRowsHost {
  readonly store: ChatRowStore;
  private post: ChatRowsPost;
  private name: () => string;
  /// `OPEN_ANSWER_MS`, set lower by a test.
  answerMs = OPEN_ANSWER_MS;

  constructor(post: ChatRowsPost, store: ChatRowStore = new ChatRowStore(), name: () => string = chatRowsNamer()) {
    this.post = post;
    this.store = store;
    this.name = name;
  }

  /// Opens a chat's rows under a sid the page names. The store holds the sid before the post, so a
  /// window that comes before the answer is kept; a refusal lets it go and the chat falls to v1.
  /// An answer later than `answerMs` is a fall too (`CHAT_ROWS_LATE`): the sid is closed, so the
  /// store drops what comes for it after.
  async open(chat: string, anchor: ChatAnchor = "end", window?: number): Promise<ChatRowsOpen> {
    const sid = this.name();
    const params: Record<string, unknown> = { sid, chat };
    params.anchor = anchor === "end" ? "end" : { rowId: anchor.rowId, side: anchor.side };
    if (window !== undefined) params.window = window;
    this.store.open(sid, anchor);
    let reply: unknown;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const late = new Promise<typeof CHAT_ROWS_LATE>((resolve) => {
      timer = setTimeout(() => resolve(CHAT_ROWS_LATE), this.answerMs);
    });
    try {
      reply = await Promise.race([this.post("chat.rows.open", params), late]);
    } catch (error) {
      this.store.close(sid);
      return { fallen: refusalCode(error) };
    } finally {
      clearTimeout(timer);
    }
    if (reply === CHAT_ROWS_LATE) {
      this.close(sid);
      return { fallen: CHAT_ROWS_LATE };
    }
    // The answer names the same sid; any other answer is a host that does not have the operation.
    if ((reply as { sid?: unknown } | null)?.sid !== sid) {
      this.store.close(sid);
      return { fallen: CHAT_ROWS_OFF };
    }
    return { sid };
  }

  close(sid: string): void {
    this.store.close(sid);
    void this.post("chat.rows.close", { sid }).catch(() => {});
  }

  /// Asks for the page before or after a row: `from`, or the edge of the stretch that holds the
  /// anchor (a gap's row, `gapBefore`, pages before from itself). Or a fold's rows. False when
  /// nothing is held to page from or a page is out: one page a sub at a time.
  page(
    sid: string,
    side: "before" | "after",
    options: { from?: number; fold?: number; maxBytes?: number } = {},
  ): boolean {
    const rowId = options.from ?? this.store.edge(sid, side);
    if (rowId === null || this.store.pageOut(sid)) return false;
    this.store.pageAsked(sid, side, rowId, options.fold);
    const params: Record<string, unknown> = { sid, [side]: rowId };
    if (options.fold !== undefined) params.fold = options.fold;
    if (options.maxBytes !== undefined) params.maxBytes = options.maxBytes;
    this.post("chat.rows.page", params).catch(() => {
      // Refused (`chat.rows.busy`, or the sub is gone): the ask is not out.
      this.store.applyBatch([{ kind: "chatError", sid, method: "page", code: "refused" }]);
    });
    return true;
  }

  /// Reads a range of a row's body or a waiting prompt's text under an id the page names; the
  /// bytes come as `chatBlob`, which may come before the answer. Null when the host refused it.
  async blob(
    sid: string,
    target: BlobTarget,
    len: number,
    range: { start?: number; from?: string } = {},
  ): Promise<string | null> {
    const id = this.name();
    const params: Record<string, unknown> = { sid, id, len, ...target };
    if (range.start !== undefined) params.start = range.start;
    if (range.from !== undefined) params.from = range.from;
    this.store.blobAsked(sid, id, target);
    try {
      await this.post("chat.rows.blob", params);
    } catch {
      this.store.blobFailed(sid, id);
      return null;
    }
    return id;
  }

  /// The host's event: applies the batch, then answers `taken`. A string that is not a change is
  /// skipped; the batch is still taken, or the host would wait on it for good.
  receive(event: ChatRowsBatch): void {
    const changes: ChatChange[] = [];
    for (const line of event.changes) {
      const change = parseChange(line);
      if (change) changes.push(change);
    }
    try {
      this.store.applyBatch(changes);
    } finally {
      void this.post("chat.rows.taken", { batch: event.batch }).catch(() => {});
    }
  }
}
