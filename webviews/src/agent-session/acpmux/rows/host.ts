// The page's side of the host contract for a chat's rows (decision 224): five operations under
// `cmux.agent.chat.rows.*` and one event, `{batch, changes}`. Each change string is one change as
// the client core gave it; this decodes them, hands the batch to the store and answers `taken`
// at once, so the host sends the next. It holds at most the batch it is applying, and queues
// nothing behind a render: a page that stalls costs the daemon's credit, not this page memory.
import { ChatRowStore, type BlobTarget, type ChatAnchor } from "./store";
import { parseChange, type ChatChange } from "./wire";

/// The host's `postNative`, injected so a test (and the browser dev slot) can give its own.
export type ChatRowsPost = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export type ChatRowsBatch = { batch: number; changes: readonly string[] };

/// What `open` gives: the sid the host made, or the code the chat falls to v1 with.
export type ChatRowsOpen = { sid: string } | { fallen: string };

/// A host with no such operation (the browser dev slot, the mock) is `off`, as a host that has it
/// and says so.
export const CHAT_ROWS_OFF = "chat.rows.off";

function refusalCode(error: unknown): string {
  const known = error as { code?: unknown; details?: { protocol?: unknown } } | null;
  if (known?.details?.protocol === "cmux.protocol.unknown_op") return CHAT_ROWS_OFF;
  if (typeof known?.code === "string" && known.code) return known.code;
  return CHAT_ROWS_OFF;
}

export class ChatRowsHost {
  readonly store: ChatRowStore;
  private post: ChatRowsPost;

  constructor(post: ChatRowsPost, store: ChatRowStore = new ChatRowStore()) {
    this.post = post;
    this.store = store;
  }

  /// Opens a chat's rows. The sid is the host's name for the sub; the page reads nothing into it.
  async open(chat: string, anchor: ChatAnchor = "end", window?: number): Promise<ChatRowsOpen> {
    const params: Record<string, unknown> = { chat };
    if (anchor !== "end") params.anchor = { rowId: anchor.rowId, side: anchor.side };
    else params.anchor = "end";
    if (window !== undefined) params.window = window;
    let reply: unknown;
    try {
      reply = await this.post("chat.rows.open", params);
    } catch (error) {
      return { fallen: refusalCode(error) };
    }
    const sid = (reply as { sid?: unknown } | null)?.sid;
    if (typeof sid !== "string" || !sid) return { fallen: CHAT_ROWS_OFF };
    this.store.open(sid, anchor);
    return { sid };
  }

  close(sid: string): void {
    this.store.close(sid);
    void this.post("chat.rows.close", { sid }).catch(() => {});
  }

  /// Asks for the page before or after the store's edge (or a fold's rows). False when nothing is
  /// held to page from or a page is out: one page a sub at a time.
  page(sid: string, side: "before" | "after", options: { fold?: number; maxBytes?: number } = {}): boolean {
    const rowId = this.store.edge(sid, side);
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

  /// Reads a range of a row's body or a waiting prompt's text; the bytes come as `chatBlob`.
  async blob(
    sid: string,
    target: BlobTarget,
    len: number,
    range: { start?: number; from?: string } = {},
  ): Promise<boolean> {
    const params: Record<string, unknown> = { sid, len, ...target };
    if (range.start !== undefined) params.start = range.start;
    if (range.from !== undefined) params.from = range.from;
    let reply: unknown;
    try {
      reply = await this.post("chat.rows.blob", params);
    } catch {
      return false;
    }
    const id = (reply as { id?: unknown } | null)?.id;
    if (typeof id !== "string") return false;
    this.store.blobAsked(sid, id, target);
    return true;
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
