// The one file of a page that knows the transport (plans/cmux-next/react-pages.md 1.1).
//
// Pages call `PageClient`. Today the client speaks the pane-protocol envelope
// (plans/cmux-next/pane-protocol.md "Wire": call/ok/err, sub/ev/unsub) over the WebKit message
// handler `cmuxPage`; the host relays each call to the namespace's owner. When the router is in the
// daemon, `createPageClient` builds a protocol `Session` over the handshake transport and resolves
// the namespace instead. No page file changes.

export interface PageError extends Error {
  code: string;
  retryable: boolean;
  /** The owner's structured details (pane-protocol `err.details`), when it sent any. */
  details?: unknown;
}

export function pageError(code: string, message: string, retryable = false, details?: unknown): PageError {
  const error = new Error(message) as PageError;
  error.name = "PageError";
  error.code = code;
  error.retryable = retryable;
  if (details !== undefined) error.details = details;
  return error;
}

export function isPageError(value: unknown): value is PageError {
  return value instanceof Error && typeof (value as PageError).code === "string";
}

export type PageHandler = (params: unknown) => unknown | Promise<unknown>;

/** Options of one call. */
export interface PageCallOptions {
  /** Pane-protocol decision 31: the intent's operation id; the owner applies it once and echoes it on events. */
  opid?: string;
  /** Aborting (navigation, tab close, the caller gives up) sends `{t:"cancel", id}` so the host
   * cancels the op, and rejects at once with `cmux.op.cancelled`. A cancelled mutation may or may
   * not have applied: retry it with the SAME opid (the owner's idempotency key). */
  signal?: AbortSignal;
}

/** Envelope fields of one event beyond its data. */
export interface PageEventMeta {
  /** Decision 31: the opid of the call that caused the event. */
  opid?: string;
}

export interface PageClient {
  /** One op call; rejects with a `PageError`. */
  call<R>(op: string, params: unknown, options?: PageCallOptions): Promise<R>;
  /** Subscribes to an event stream (with an optional filter); resolves to the unsubscribe function. */
  subscribe<E>(
    stream: string,
    onEvent: (data: E, seq: number, meta?: PageEventMeta) => void,
    filter?: Record<string, unknown>,
  ): Promise<() => void>;
  /** Serves an op the host calls on the page (both peers may call). Returns the unregister function. */
  handle(op: string, handler: PageHandler): () => void;
}

type Envelope =
  | { t: "call"; id: number; op: string; params?: unknown; opid?: string }
  | { t: "ok"; id: number; value?: unknown }
  | { t: "err"; id: number; code: string; message: string; retryable?: boolean; details?: unknown }
  | { t: "sub"; id: number; stream: string; filter?: Record<string, unknown> }
  | { t: "ev"; sub: number; seq: number; data: unknown; opid?: string }
  | { t: "unsub"; sub: number }
  | { t: "cancel"; id: number };

/** A reply-capable message handler (`WKScriptMessageHandlerWithReply`). */
export interface ReplyHandler {
  postMessage(body: unknown): Promise<unknown>;
}

export const RECEIVE_NAME = "__cmuxPageReceive";

/**
 * The bridge client: the page posts envelopes and awaits the reply; the host pushes events and its
 * own calls through `window.__cmuxPageReceive(envelope)`.
 */
export class BridgePageClient implements PageClient {
  private nextId = 1;
  private readonly listeners = new Map<number, (data: unknown, seq: number, meta?: PageEventMeta) => void>();
  private readonly lastSeq = new Map<number, number>();
  private readonly handlers = new Map<string, PageHandler>();

  constructor(
    private readonly handler: ReplyHandler,
    target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
  ) {
    target[RECEIVE_NAME] = (message: unknown) => this.receive(message);
  }

  async call<R>(op: string, params: unknown, options?: PageCallOptions): Promise<R> {
    const signal = options?.signal;
    const cancelled = () =>
      pageError(
        "cmux.op.cancelled",
        "the caller cancelled the op",
        true,
        options?.opid ? { opid: options.opid } : undefined,
      );
    if (signal?.aborted) throw cancelled();
    const envelope: Envelope & { id: number } =
      options?.opid === undefined
        ? { t: "call", id: this.nextId++, op, params }
        : { t: "call", id: this.nextId++, op, params, opid: options.opid };
    const reply = this.post(envelope);
    if (!signal) return (await reply) as R;
    return await new Promise<R>((resolve, reject) => {
      const onAbort = () => {
        // The host cancels the op; its late answer for this id is ignored.
        void this.handler.postMessage({ t: "cancel", id: envelope.id } satisfies Envelope).catch(() => undefined);
        reject(cancelled());
      };
      signal.addEventListener("abort", onAbort, { once: true });
      reply.then(
        (value) => {
          signal.removeEventListener("abort", onAbort);
          if (!signal.aborted) resolve(value as R);
        },
        (error: unknown) => {
          signal.removeEventListener("abort", onAbort);
          if (!signal.aborted) reject(error);
        },
      );
    });
  }

  async subscribe<E>(
    stream: string,
    onEvent: (data: E, seq: number, meta?: PageEventMeta) => void,
    filter?: Record<string, unknown>,
  ): Promise<() => void> {
    const envelope: Envelope & { id: number } = filter
      ? { t: "sub", id: this.nextId++, stream, filter }
      : { t: "sub", id: this.nextId++, stream };
    const value = (await this.post(envelope)) as { sub?: unknown } | undefined;
    const sub = value?.sub;
    if (typeof sub !== "number") throw pageError("cmux.protocol.invalid_result", `subscribe ${stream}: no sub id`);
    this.listeners.set(sub, onEvent as (data: unknown, seq: number, meta?: PageEventMeta) => void);
    return () => {
      if (!this.listeners.delete(sub)) return;
      this.lastSeq.delete(sub);
      void this.handler.postMessage({ t: "unsub", sub } satisfies Envelope).catch(() => undefined);
    };
  }

  handle(op: string, handler: PageHandler): () => void {
    this.handlers.set(op, handler);
    return () => {
      if (this.handlers.get(op) === handler) this.handlers.delete(op);
    };
  }

  private async post(envelope: Envelope & { id: number }): Promise<unknown> {
    let reply: unknown;
    try {
      reply = await this.handler.postMessage(envelope);
    } catch (error) {
      throw pageError("cmux.protocol.closed", error instanceof Error ? error.message : String(error), true);
    }
    const message = reply as Partial<Envelope> | null;
    if (message?.t === "ok" && message.id === envelope.id) return (message as { value?: unknown }).value;
    if (message?.t === "err") {
      const err = message as { code?: string; message?: string; retryable?: boolean; details?: unknown };
      throw pageError(
        err.code ?? "cmux.protocol.error",
        err.message ?? "request failed",
        err.retryable ?? false,
        err.details,
      );
    }
    throw pageError("cmux.protocol.invalid_result", "malformed reply");
  }

  /** Host to page. Exposed for tests; the host calls it through `window.__cmuxPageReceive`. */
  receive(message: unknown): void {
    const envelope = message as Partial<Envelope> | null;
    if (envelope?.t === "ev") {
      const { sub, seq, data, opid } = envelope as { sub: number; seq: number; data: unknown; opid?: unknown };
      const listener = this.listeners.get(sub);
      if (!listener) return;
      // Events of one subscription are ordered from 1; a duplicate or old event is dropped.
      if (seq <= (this.lastSeq.get(sub) ?? 0)) return;
      this.lastSeq.set(sub, seq);
      listener(data, seq, typeof opid === "string" ? { opid } : {});
      return;
    }
    if (envelope?.t === "call") {
      const { id, op, params } = envelope as { id: number; op: string; params?: unknown };
      void this.answer(id, op, params);
    }
  }

  private async answer(id: number, op: string, params: unknown): Promise<void> {
    const handler = this.handlers.get(op);
    let reply: Envelope;
    if (!handler) {
      reply = { t: "err", id, code: "cmux.protocol.unknown_op", message: op };
    } else {
      try {
        reply = { t: "ok", id, value: (await handler(params)) ?? null };
      } catch (error) {
        reply = {
          t: "err",
          id,
          code: "cmux.page.failed",
          message: error instanceof Error ? error.message : String(error),
        };
      }
    }
    await this.handler.postMessage(reply).catch(() => undefined);
  }
}

/** The WebKit handler of the page bridge, when the page runs in the app. */
export function findReplyHandler(name = "cmuxPage", target: unknown = globalThis): ReplyHandler | null {
  const handlers = (target as { webkit?: { messageHandlers?: Record<string, unknown> } }).webkit?.messageHandlers;
  const handler = handlers?.[name] as ReplyHandler | undefined;
  return handler && typeof handler.postMessage === "function" ? handler : null;
}

/**
 * The client for this page: the in-app bridge when the host installed it, else `fallback` (the
 * dev loop's mock provider), else null (the page shows the disconnected state).
 */
export function createPageClient(fallback?: () => PageClient): PageClient | null {
  const handler = findReplyHandler();
  if (handler) return new BridgePageClient(handler);
  return fallback ? fallback() : null;
}
