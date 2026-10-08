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
 * Set to `true` by the host before page code runs when the document loads in a parked pooled host
 * (the prewarmed spare, PageWebView's pooled recipe). The spare has no routes yet, so the client
 * holds every call and subscription until the host claims the document for a page.
 */
export const PARKED_NAME = "__cmuxPageParked";

/**
 * The host's claim of a parked document (`{route?}`): the claim's routes are bound, so the client
 * shows `route` (a URL fragment), sends what it held, and acknowledges with `{claimed: true}`. A
 * document that was not parked (it already ran against other routes) answers
 * `cmux.page.not_parked`, and the host reloads it.
 */
export const CLAIM_OP = "cmux.page.claim";

/** How many not-yet-registered subscriptions, and events per subscription, the client holds. */
const EARLY_SUBS = 16;
const EARLY_EVENTS = 64;

/** A call or subscription a parked document holds until its claim. */
interface Held {
  envelope: Envelope & { id: number };
  resolve: (reply: unknown) => void;
  reject: (error: unknown) => void;
}

/** The part of `window.location` a claim uses. */
interface ClaimLocation {
  hash: string;
  replace(url: string): void;
}

/**
 * The bridge client: the page posts envelopes and awaits the reply; the host pushes events and its
 * own calls through `window.__cmuxPageReceive(envelope)`. Every page that boots through it serves
 * the pooled host's claim (`CLAIM_OP`); no page code takes part.
 */
export class BridgePageClient implements PageClient {
  private nextId = 1;
  private readonly listeners = new Map<number, (data: unknown, seq: number, meta?: PageEventMeta) => void>();
  private readonly lastSeq = new Map<number, number>();
  private readonly handlers = new Map<string, PageHandler>();
  /** Events for a sub id whose subscribe reply the page has not read yet, replayed on registration. */
  private readonly early = new Map<number, { data: unknown; seq: number; meta: PageEventMeta }[]>();
  /** True from boot in a parked pooled host until the claim (`PARKED_NAME`). */
  private parked: boolean;
  private held: Held[] = [];
  private readonly location: ClaimLocation | undefined;

  constructor(
    private readonly handler: ReplyHandler,
    target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
  ) {
    target[RECEIVE_NAME] = (message: unknown) => this.receive(message);
    this.parked = target[PARKED_NAME] === true;
    this.location = target.location as ClaimLocation | undefined;
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
        // A held call is dropped before the host sees it; else the host cancels the op, and its
        // late answer for this id is ignored.
        if (!this.drop(envelope.id))
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
    const listener = onEvent as (data: unknown, seq: number, meta?: PageEventMeta) => void;
    this.listeners.set(sub, listener);
    const held = this.early.get(sub) ?? [];
    this.early.delete(sub);
    for (const event of held.sort((a, b) => a.seq - b.seq))
      this.deliver(sub, listener, event.data, event.seq, event.meta);
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

  /** Sends an envelope, or holds it while the document is parked. */
  private transmit(envelope: Envelope & { id: number }): Promise<unknown> {
    if (!this.parked) return this.handler.postMessage(envelope);
    return new Promise((resolve, reject) => this.held.push({ envelope, resolve, reject }));
  }

  /** Drops a held envelope (its caller gave up); false when it was already sent. */
  private drop(id: number): boolean {
    const index = this.held.findIndex((held) => held.envelope.id === id);
    if (index === -1) return false;
    const [held] = this.held.splice(index, 1);
    held?.reject(new Error("cancelled while parked"));
    return true;
  }

  /** The host claimed this document: show the claim's route, then send what was held, in order. */
  private claim(params: unknown): unknown {
    if (!this.parked) throw pageError("cmux.page.not_parked", "the document already ran");
    const route = (params as { route?: unknown } | null)?.route;
    if (typeof route === "string" && route.startsWith("#") && this.location && this.location.hash !== route)
      this.location.replace(route);
    this.parked = false;
    const held = this.held;
    this.held = [];
    for (const { envelope, resolve, reject } of held) this.handler.postMessage(envelope).then(resolve, reject);
    return { claimed: true };
  }

  private async post(envelope: Envelope & { id: number }): Promise<unknown> {
    let reply: unknown;
    try {
      reply = await this.transmit(envelope);
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

  /** Events of one subscription are ordered from 1; a duplicate or old event is dropped. */
  private deliver(
    sub: number,
    listener: (data: unknown, seq: number, meta?: PageEventMeta) => void,
    data: unknown,
    seq: number,
    meta: PageEventMeta,
  ): void {
    if (seq <= (this.lastSeq.get(sub) ?? 0)) return;
    this.lastSeq.set(sub, seq);
    listener(data, seq, meta);
  }

  /** Bounded: a sub id the page never registers (a cancelled subscribe) cannot grow memory. */
  private hold(sub: number, event: { data: unknown; seq: number; meta: PageEventMeta }): void {
    if (!this.early.has(sub) && this.early.size >= EARLY_SUBS) {
      const oldest = this.early.keys().next().value;
      if (oldest !== undefined) this.early.delete(oldest);
    }
    const held = this.early.get(sub) ?? [];
    if (held.length >= EARLY_EVENTS) held.shift();
    held.push(event);
    this.early.set(sub, held);
  }

  /** Host to page. Exposed for tests; the host calls it through `window.__cmuxPageReceive`. */
  receive(message: unknown): void {
    const envelope = message as Partial<Envelope> | null;
    if (envelope?.t === "ev") {
      const { sub, seq, data, opid } = envelope as { sub: number; seq: number; data: unknown; opid?: unknown };
      const meta: PageEventMeta = typeof opid === "string" ? { opid } : {};
      const listener = this.listeners.get(sub);
      if (!listener) {
        this.hold(sub, { data, seq, meta });
        return;
      }
      this.deliver(sub, listener, data, seq, meta);
      return;
    }
    if (envelope?.t === "call") {
      const { id, op, params } = envelope as { id: number; op: string; params?: unknown };
      void this.answer(id, op, params);
    }
  }

  private async answer(id: number, op: string, params: unknown): Promise<void> {
    const handler = op === CLAIM_OP ? (claim: unknown) => this.claim(claim) : this.handlers.get(op);
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
          code: isPageError(error) ? error.code : "cmux.page.failed",
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
