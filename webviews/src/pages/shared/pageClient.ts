// The one file of a page that knows the transport (plans/cmux-next/react-pages.md 1.1).
//
// Pages call `PageClient`. Today the client speaks the pane-protocol envelope
// (plans/cmux-next/pane-protocol.md "Wire": call/ok/err, sub/ev/unsub) over the WebKit message
// handler `cmuxPage`; the host relays each call to the namespace's owner. When the router is in the
// daemon, `createPageClient` builds a protocol `Session` over the handshake transport and resolves
// the namespace instead. No page file changes.

import { holdPaintForClaim } from "./paintGate";
import { installNativeMenu, NATIVE_MENU_OP } from "../../ui/nativeMenu";
import { serveOracleState } from "../../protocol/oracle-state";
import { watchPageEdits } from "./pageEdits";

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
  /**
   * Decisions 15 and 32: the host dropped events of this stream before this one (the page was
   * hidden or frozen and the stream keeps only its newest). The seq does not skip; read the state
   * again instead of applying this event on top of what the page has.
   */
  gap?: true;
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
  /**
   * The restore the host handed this document when it came back after a discard
   * (`takePageRestore`), taken when the client was made, before any page code renders; null (or
   * absent, for a mock) when the document was not discarded. A page applies `state` to its store
   * before its first render.
   */
  readonly restore?: PageRestore | null;
  /**
   * The fragment the host showed this document with: its load URL's, or the pooled host's claim
   * route (`CLAIM_OP`). The page's saved state (pageState.ts) puts its own route back only when the
   * restored document comes with the same one. Absent for a mock.
   */
  readonly entryRoute?: string;
}

type Envelope =
  | { t: "call"; id: number; op: string; params?: unknown; opid?: string }
  | { t: "ok"; id: number; value?: unknown }
  | { t: "err"; id: number; code: string; message: string; retryable?: boolean; details?: unknown }
  | { t: "sub"; id: number; stream: string; filter?: Record<string, unknown> }
  | { t: "ev"; sub: number; seq: number; data: unknown; opid?: string; gap?: boolean }
  | { t: "evs"; events: unknown[] }
  | { t: "unsub"; sub: number }
  | { t: "cancel"; id: number };

/** A reply-capable message handler (`WKScriptMessageHandlerWithReply`). */
export interface ReplyHandler {
  postMessage(body: unknown): Promise<unknown>;
}

export const RECEIVE_NAME = "__cmuxPageReceive";
/** The batch form: the host sends one frame's envelopes as one script (PageScriptPipeline). */
export const RECEIVE_MANY_NAME = "__cmuxPageReceiveMany";
/**
 * The page push channel (Chromium): where the host's page script defines it, the
 * client registers its receiver of envelope runs with it, and the host sends each run as data
 * instead of a `__cmuxPageReceiveMany` script, as Chrome's WebUI pages get Mojo messages
 * (ChromiumPageHostBridge.pushReceiverScript). The script globals stay for every other host.
 */
export const LISTEN_NAME = "__cmuxPageHostListen";

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

/**
 * Built in for every page: `{reason, on}` sets or ends one of the page's own keep
 * reasons, which keep it from being frozen or discarded while hidden. The host refuses any other
 * reason; the page can only add reasons, and they end with its document (reload, crash).
 */
export const KEEP_ALIVE_OP = "cmux.page.keepAlive";

/**
 * The keep reasons a page may set (the host's `PageKeepReasons.pageSettable`): what only its
 * document knows. The host observes the rest itself (a drop it reads, dictation, Web Inspector).
 */
export type PageKeepReason = "user_edits" | "form_interaction" | "before_unload" | "draft" | "capture";

/** The reasons that say the page holds edits; `editsSaved()` ends them for every holder. */
const EDIT_REASONS: readonly PageKeepReason[] = ["user_edits", "form_interaction"];

/**
 * The page's keep reasons as it last told the host, one per document (`pageKeepAliveFor`). Each part
 * of the page that sets a reason holds it as its own `holder` (a store, a composer, the automatic
 * edits of pageEdits.ts); the reason holds while one holder does. `set` sends `cmux.page.keepAlive`
 * only when a reason starts or ends, so a holder may call it on every state change (no IPC per
 * keystroke). A host without the op (an older app) answers `unknown_op`, which is ignored.
 */
export class PageKeepAlive {
  private readonly holders = new Map<PageKeepReason, Set<object>>();

  constructor(private readonly client: PageClient | null) {}

  /** Whether the page last said `reason` holds. */
  has(reason: PageKeepReason): boolean {
    return this.holders.has(reason);
  }

  /** `holder` (by default this object) holds `reason` from now on, or no longer does. */
  set(reason: PageKeepReason, on: boolean, holder: object = this): void {
    const holders = this.holders.get(reason);
    if (on) {
      if (holders) holders.add(holder);
      else {
        this.holders.set(reason, new Set([holder]));
        this.send(reason, true);
      }
      return;
    }
    if (!holders?.delete(holder) || holders.size > 0) return;
    this.end(reason);
  }

  /**
   * The page's edits are saved (on disk, applied or sent): `user_edits` and `form_interaction` end
   * for every holder, the automatic ones included. A `cmux.page.edits.saved` event the page
   * dispatches (pageEdits.ts) ends them here too.
   */
  editsSaved(): void {
    for (const reason of EDIT_REASONS) this.end(reason);
  }

  private end(reason: PageKeepReason): void {
    if (this.holders.delete(reason)) this.send(reason, false);
  }

  private send(reason: PageKeepReason, on: boolean): void {
    this.client?.call<unknown>(KEEP_ALIVE_OP, { reason, on }).catch((error: unknown) => {
      if (!(isPageError(error) && error.code === "cmux.protocol.unknown_op")) console.warn("cmux keepAlive", error);
    });
  }
}

const keepAlives = new WeakMap<PageClient, PageKeepAlive>();

/** The one `PageKeepAlive` of `client`'s document; null gives one that sends nothing. */
export function pageKeepAliveFor(client: PageClient | null): PageKeepAlive {
  if (!client) return new PageKeepAlive(null);
  let keep = keepAlives.get(client);
  if (!keep) {
    keep = new PageKeepAlive(client);
    keepAlives.set(client, keep);
  }
  return keep;
}

/**
 * Set by the host before page code runs when the document comes back after a discard
 * (PageWebView+Discard.swift): `{wasDiscarded: true, state}`, where `state` is what the page saved
 * when it hid (null when it saved none). Chrome's `document.wasDiscarded` plus the page's own state.
 * The host also puts that state back in sessionStorage, so `readPageState` (pageLifecycle.ts) reads it.
 */
export const RESTORE_NAME = "__cmuxPageRestore";

/** What a document that comes back after a discard gets (`takePageRestore`). */
export interface PageRestore {
  wasDiscarded: true;
  /** The state the page saved when it hid; null when it saved none. */
  state: unknown;
}

/**
 * The restore the host handed this document, once. The bridge client takes it when it is made
 * (`BridgePageClient.restore`), which every page does before its first render. Null when the
 * document is not a restored one or the restore was taken already.
 */
export function takePageRestore(
  target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
): PageRestore | null {
  const value = target[RESTORE_NAME] as { wasDiscarded?: unknown; state?: unknown } | null | undefined;
  delete target[RESTORE_NAME];
  if (!value || value.wasDiscarded !== true) return null;
  return { wasDiscarded: true, state: value.state ?? null };
}

/** How many not-yet-registered subscriptions, and events per subscription, the client holds. */
const EARLY_SUBS = 16;
const EARLY_EVENTS = 64;

/** A call or subscription a parked document holds until its claim. */
interface Held {
  envelope: Envelope & { id: number };
  resolve: (reply: unknown) => void;
  reject: (error: unknown) => void;
}

/** The part of `window.location` a claim and the entry route use. */
interface ClaimLocation {
  hash: string;
  replace(url: string): void;
}

/**
 * The bridge client: the page posts envelopes and awaits the reply; the host pushes events and its
 * own calls through `window.__cmuxPageReceive(envelope)`, or one frame's envelopes through
 * `window.__cmuxPageReceiveMany(envelopes)` or, on the page push channel, the receiver it registers
 * with `__cmuxPageHostListen` (`LISTEN_NAME`). Every page that boots through it serves
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
  readonly restore: PageRestore | null;
  private entry: string;

  constructor(
    private readonly handler: ReplyHandler,
    target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
  ) {
    target[RECEIVE_NAME] = (message: unknown) => this.receive(message);
    target[RECEIVE_MANY_NAME] = (messages: unknown) => this.receiveMany(messages);
    const listen = target[LISTEN_NAME];
    if (typeof listen === "function") listen((messages: unknown) => this.receiveMany(messages));
    this.parked = target[PARKED_NAME] === true;
    this.restore = takePageRestore(target);
    this.location = target.location as ClaimLocation | undefined;
    this.entry = this.location?.hash ?? "";
  }

  get entryRoute(): string {
    return this.entry;
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
    if (typeof route === "string" && route.startsWith("#")) {
      if (this.location && this.location.hash !== route) this.location.replace(route);
      this.entry = route;
    }
    this.parked = false;
    const held = this.held;
    this.held = [];
    for (const { envelope, resolve, reject } of held) this.handler.postMessage(envelope).then(resolve, reject);
    // The host's next paint report (its pane's hold) waits for the claimed page's first screen.
    holdPaintForClaim();
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
      const err = message as {
        code?: string;
        message?: string;
        retryable?: boolean;
        details?: unknown;
      };
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

  /**
   * Host to page, one frame's envelopes in send order (`window.__cmuxPageReceiveMany`). A listener
   * that throws does not stop the envelopes after it, as when each was its own script.
   */
  receiveMany(messages: unknown): void {
    if (!Array.isArray(messages)) return;
    for (const message of messages) {
      try {
        this.receive(message);
      } catch (error) {
        console.error(error);
      }
    }
  }

  /** Host to page. Exposed for tests; the host calls it through `window.__cmuxPageReceive`. */
  receive(message: unknown): void {
    const envelope = message as Partial<Envelope> | null;
    if (envelope?.t === "evs") {
      // Decision 32: events the host held while the page was hidden, in send order.
      const { events } = envelope as { events?: unknown };
      if (Array.isArray(events)) for (const event of events) this.receive(event);
      return;
    }
    if (envelope?.t === "ev") {
      const { sub, seq, data, opid, gap } = envelope as {
        sub: number;
        seq: number;
        data: unknown;
        opid?: unknown;
        gap?: unknown;
      };
      const meta: PageEventMeta = typeof opid === "string" ? { opid } : {};
      if (gap === true) meta.gap = true;
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
  if (handler) {
    const client = new BridgePageClient(handler);
    // The page's right-click menus are the app's native menus (ui/nativeMenu.ts).
    installNativeMenu((request) => client.call(NATIVE_MENU_OP, request));
    // The refactor oracle's page state, in developer builds only (protocol/oracle-state.ts).
    serveOracleState(client);
    // Edits and form input keep the hidden page from being discarded, for every page with no page
    // code (pageEdits.ts).
    if (typeof document !== "undefined") watchPageEdits(document, window, pageKeepAliveFor(client));
    return client;
  }
  return fallback ? fallback() : null;
}
