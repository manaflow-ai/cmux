// IntentStore: local-first state for pages (plans/cmux-next/zero-latency.md).
//
// Every user intent applies at once to local state (the input frame paints it), then goes to the
// backend with a client-generated operation id (`opid`, pane-protocol decision 31). The store
// keeps two layers: `base`, the state the backend confirmed, and the pending intents. What
// renders is the base with the pending intents folded over it, in input order.
//
// Rules (each has a test in test/intents.test.ts):
// - (a) dispatch applies synchronously and notifies before it returns; no await on the input path.
// - (b) each intent gets an opid; a resend after a reconnect reuses it.
// - (c) intents on one resource are sent one at a time, in input order; later ones fold over the
//   earlier optimistic state. Different resources run in parallel.
// - (d) `ok` folds the intent into the base (or, for `confirm: "event"`, waits for the event that
//   echoes its opid); a late base (`load`, `resync`) replaces the base and pending intents still
//   apply on top, so a slow read never undoes a newer input. Nothing in between shows the
//   pre-intent state.
// - (e) `err` drops the intent: the visible state is recomputed from the base, so the revert is
//   exact, and a specific error is recorded. Later intents on the resource are rebased (default)
//   or cancelled (`onPriorRefused: "cancel"`).
// - (h) loading/saving flags are derived (`pending`, `status`); a newer `load` aborts the older
//   one; a superseding intent drops the queued one it replaces.

import { ProtocolError, ProtocolErrorCode } from "../errors";

/** What the store sends through: a protocol `Session` or a page bridge `PageClient`. */
export interface IntentSender {
  call(op: string, params: unknown, options?: { signal?: AbortSignal; opid?: string }): Promise<unknown>;
}

/** One kind of user intent: how it changes local state and how it reaches the backend. */
export interface IntentKind<S, P = any, R = any> {
  /** The op to call. `null` makes the intent local: it settles into the base at once. */
  op: string | null;
  /** The ordering key. Intents with the same resource are sent and acknowledged in order. */
  resource(params: P): string;
  /** The optimistic change. Pure; it runs again whenever the base changes under it. */
  apply(state: S, params: P): S;
  /** Wire params; defaults to `params`. */
  wire?(params: P): unknown;
  /**
   * Folds the backend's answer into the base on `ok`. Defaults to `apply(base, params)`, the
   * optimistic change made authoritative.
   */
  settle?(base: S, params: P, result: R): S;
  /**
   * "ok" (default): the `ok` reply confirms the intent. "event": the intent stays optimistic until
   * an event echoes its opid (`receive`), for providers whose events carry the authoritative
   * state; the `ok` only lets the next intent on the resource go.
   */
  confirm?: "ok" | "event";
  /**
   * A newer intent of this kind on the same resource drops an older one that is still queued
   * (not yet sent). Use it only for intents that set a value (not toggles): the newer one must
   * not depend on the one it drops.
   */
  supersede?: boolean;
  /**
   * Also abort an older one that is in flight (its `AbortSignal` fires and its answer is
   * ignored). Only for reads and idempotent sets: the backend may still have applied it.
   */
  abortSuperseded?: boolean;
  /** When an earlier intent on the same resource is refused: rebase onto the new base (default) or cancel. */
  onPriorRefused?: "rebase" | "cancel";
  /** A specific message for a refusal. Defaults to the backend's message. */
  describeError?(error: ProtocolError, params: P): string;
}

export type IntentPhase = "queued" | "sent" | "acked" | "waiting";

/** One pending intent, as `pending()` lists it. */
export interface PendingIntent {
  readonly opid: string;
  readonly kind: string;
  readonly resource: string;
  readonly params: unknown;
  readonly phase: IntentPhase;
  /** performance.now() at dispatch. */
  readonly at: number;
}

export interface IntentError {
  readonly opid: string;
  readonly kind: string;
  readonly op: string | null;
  readonly resource: string;
  readonly code: string;
  readonly message: string;
  readonly params: unknown;
}

export type IntentOutcome =
  | { status: "confirmed"; result: unknown }
  | { status: "refused"; error: IntentError }
  | { status: "cancelled"; error: IntentError }
  | { status: "superseded" };

export type ResourceStatus = "idle" | "pending" | "waiting" | "refused";

export type IntentTraceType =
  | "dispatch"
  | "send"
  | "resend"
  | "ok"
  | "err"
  | "event"
  | "confirm"
  | "supersede"
  | "cancel"
  | "load"
  | "load-abort"
  | "resync"
  | "duplicate";

export interface IntentTrace {
  readonly at: number;
  readonly type: IntentTraceType;
  readonly opid?: string;
  readonly kind?: string;
  readonly resource?: string;
  readonly detail?: string;
}

/** Derived, immutable view of the queue for rendering (stable until the queue changes). */
export interface IntentMeta {
  readonly pending: readonly PendingIntent[];
  readonly errors: readonly IntentError[];
  /** True while a `load` is running. */
  readonly loading: boolean;
}

export interface IntentStoreOptions<S, K> {
  initial: S;
  kinds: K;
  sender?: IntentSender | null;
  /** Prefix of generated opids; defaults to a random one per store. */
  opidPrefix?: string;
  /** Size of the trace ring buffer (default 200). */
  traceLimit?: number;
  /** Called for every trace entry (devtools, tests). */
  onTrace?(entry: IntentTrace): void;
  /** How many refusals `errors` keeps (default 20). */
  errorLimit?: number;
}

type KindMap<S> = Record<string, IntentKind<S, any, any>>;
type ParamsOf<K> = K extends IntentKind<any, infer P, any> ? P : never;

interface IntentRecord {
  opid: string;
  kind: string;
  def: IntentKind<any, any, any>;
  resource: string;
  params: unknown;
  phase: IntentPhase;
  at: number;
  attempt: number;
  controller: AbortController | null;
  /** The base `loadSeq` at the time the intent was acknowledged (event-confirmed kinds). */
  ackedBeforeLoad: number;
  waiters: Array<(outcome: IntentOutcome) => void>;
}

const OPID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

/** Decision 31: an opid is 1 to 128 characters of [A-Za-z0-9._:-]. */
export function isOpid(value: unknown): value is string {
  return typeof value === "string" && OPID_PATTERN.test(value);
}

function randomPrefix(): string {
  const bytes = new Uint8Array(6);
  globalThis.crypto?.getRandomValues?.(bytes);
  let out = "";
  for (const byte of bytes) out += (byte % 36).toString(36);
  return out === "000000" ? Math.random().toString(36).slice(2, 8) : out;
}

const now = () => (typeof performance !== "undefined" ? performance.now() : Date.now());

function toProtocolError(error: unknown): ProtocolError {
  if (error instanceof ProtocolError) return error;
  const record = error as { code?: unknown; message?: unknown; retryable?: unknown } | null;
  if (record && typeof record.code === "string") {
    return new ProtocolError(record.code, String(record.message ?? record.code), {
      retryable: record.retryable === true,
    });
  }
  return new ProtocolError(ProtocolErrorCode.internal, error instanceof Error ? error.message : String(error));
}

/** A lost link (the session or bridge closed): the intent waits for a new sender and is resent. */
function isLinkLoss(error: ProtocolError): boolean {
  return error.code === ProtocolErrorCode.closed;
}

export class IntentStore<S, K extends KindMap<S> = KindMap<S>> {
  private base: S;
  private visible: S;
  private dirty = false;
  private readonly kinds: K;
  private sender: IntentSender | null;
  private readonly prefix: string;
  private counter = 0;
  /** All pending intents in dispatch order (the fold order). */
  private records: IntentRecord[] = [];
  private readonly byOpid = new Map<string, IntentRecord>();
  /** Recently settled opids, so a duplicate answer or event is ignored. */
  private readonly settled = new Set<string>();
  private errorList: IntentError[] = [];
  private readonly listeners = new Set<() => void>();
  private readonly traceBuffer: IntentTrace[] = [];
  private readonly traceLimit: number;
  private readonly errorLimit: number;
  private readonly onTrace: ((entry: IntentTrace) => void) | undefined;
  private loadSeq = 0;
  private loadController: AbortController | null = null;
  private meta: IntentMeta | null = null;

  constructor(options: IntentStoreOptions<S, K>) {
    this.base = options.initial;
    this.visible = options.initial;
    this.kinds = options.kinds;
    this.sender = options.sender ?? null;
    this.prefix = options.opidPrefix ?? randomPrefix();
    if (!isOpid(`${this.prefix}-1`)) throw new Error(`invalid opid prefix ${this.prefix}`);
    this.traceLimit = options.traceLimit ?? 200;
    this.errorLimit = options.errorLimit ?? 20;
    this.onTrace = options.onTrace;
  }

  // Reading.

  /** The rendered state: the base with every pending intent folded over it. Stable until a change. */
  readonly getState = (): S => {
    if (this.dirty) {
      let state = this.base;
      for (const record of this.records) state = record.def.apply(state, record.params) as S;
      this.visible = state;
      this.dirty = false;
    }
    return this.visible;
  };

  /** The confirmed state, without pending intents. */
  getBase(): S {
    return this.base;
  }

  /** The queue, derived for rendering. Stable until the queue or the errors change. */
  readonly getMeta = (): IntentMeta => {
    if (!this.meta) {
      this.meta = {
        pending: this.records.map((record) => ({
          opid: record.opid,
          kind: record.kind,
          resource: record.resource,
          params: record.params,
          phase: record.phase,
          at: record.at,
        })),
        errors: this.errorList,
        loading: this.loadController !== null,
      };
    }
    return this.meta;
  };

  /** Pending intents, optionally of one resource. */
  pending(resource?: string): readonly PendingIntent[] {
    const all = this.getMeta().pending;
    return resource === undefined ? all : all.filter((intent) => intent.resource === resource);
  }

  /** A resource's status, derived from the queue: no loading flags of its own. */
  status(resource: string): ResourceStatus {
    const pending = this.records.filter((record) => record.resource === resource);
    if (pending.some((record) => record.phase === "waiting")) return "waiting";
    if (pending.length > 0) return "pending";
    return this.errorList.some((error) => error.resource === resource) ? "refused" : "idle";
  }

  get errors(): readonly IntentError[] {
    return this.errorList;
  }

  /** Clears a shown refusal (by opid), or all of them. */
  dismissError(opid?: string): void {
    const next = opid === undefined ? [] : this.errorList.filter((error) => error.opid !== opid);
    if (next.length === this.errorList.length) return;
    this.errorList = next;
    this.changed(false);
  }

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  /** The last trace entries (oldest first). */
  trace(): readonly IntentTrace[] {
    return [...this.traceBuffer];
  }

  // Writing.

  /**
   * Applies an intent now and queues it for the backend. Returns its opid at once; the state is
   * already visible to `getState` and every subscriber has been notified.
   */
  dispatch<N extends keyof K & string>(kind: N, params: ParamsOf<K[N]>): string {
    const def = this.kinds[kind];
    if (!def) throw new Error(`unknown intent kind ${kind}`);
    const opid = `${this.prefix}-${++this.counter}`;
    const resource = def.resource(params);
    this.traceEntry({ type: "dispatch", opid, kind, resource });
    if (def.op === null) {
      this.base = def.apply(this.base, params) as S;
      this.settled.add(opid);
      this.changed(true);
      return opid;
    }
    if (def.supersede) this.supersedeOlder(kind, def, resource);
    const record: IntentRecord = {
      opid,
      kind,
      def,
      resource,
      params,
      phase: "queued",
      at: now(),
      attempt: 0,
      controller: null,
      ackedBeforeLoad: 0,
      waiters: [],
    };
    this.records.push(record);
    this.byOpid.set(opid, record);
    this.changed(true);
    this.pump(resource);
    return opid;
  }

  /** Resolves when the intent is confirmed, refused, cancelled or superseded. */
  settledOutcome(opid: string): Promise<IntentOutcome> {
    const record = this.byOpid.get(opid);
    if (!record) {
      const error = this.errorList.find((entry) => entry.opid === opid);
      if (error) return Promise.resolve({ status: "refused", error });
      return Promise.resolve({ status: "confirmed", result: undefined });
    }
    return new Promise((resolve) => record.waiters.push(resolve));
  }

  /**
   * An authoritative event: `reduce` replaces or updates the base. When the event echoes an
   * `opid`, that intent is retired (its effect is now in the base). Duplicate events for a settled
   * opid still reduce the base (events carry state) but retire nothing.
   */
  receive(reduce: (base: S) => S, opid?: string): void {
    this.base = reduce(this.base);
    let resource: string | null = null;
    const record = opid === undefined ? undefined : this.byOpid.get(opid);
    if (record) {
      this.traceEntry({ type: "confirm", opid, kind: record.kind, resource: record.resource, detail: "event" });
      resource = record.resource;
      // A confirmed head that was still in flight frees the resource; its late `ok` is ignored.
      record.controller = null;
      this.retire(record, { status: "confirmed", result: undefined });
    } else {
      this.traceEntry({ type: opid !== undefined && this.settled.has(opid) ? "duplicate" : "event", opid });
    }
    this.changed(true);
    if (resource !== null) this.pump(resource);
  }

  /**
   * Replaces the base with a fresh read (a resync after a gap, a reconnect). Pending intents stay
   * and apply on top; event-confirmed intents acknowledged before `since` (a `beginRead()` token)
   * are retired, because a read started after their `ok` already contains them.
   */
  resync(base: S, since?: number): void {
    this.base = base;
    const token = since ?? Number.POSITIVE_INFINITY;
    for (const record of this.records.slice()) {
      if (record.phase === "acked" && record.ackedBeforeLoad > 0 && record.ackedBeforeLoad <= token) {
        this.retire(record, { status: "confirmed", result: undefined });
      }
    }
    this.traceEntry({ type: "resync" });
    this.changed(true);
  }

  /** A token for `resync`: reads started now contain every intent acknowledged before now. */
  beginRead(): number {
    return ++this.loadSeq;
  }

  /**
   * Loads the base. A newer `load` aborts the older one (its signal fires; its answer is ignored).
   * Pending intents keep applying over the loaded base. Resolves to the loaded base, or null when
   * a newer load or `cancelLoad` superseded it.
   */
  async load(fetch: (signal: AbortSignal) => Promise<S>): Promise<S | null> {
    this.loadController?.abort();
    if (this.loadController) this.traceEntry({ type: "load-abort" });
    const controller = new AbortController();
    this.loadController = controller;
    const token = this.beginRead();
    this.traceEntry({ type: "load" });
    this.changed(false);
    try {
      const base = await fetch(controller.signal);
      if (controller.signal.aborted) return null;
      this.loadController = null;
      this.resync(base, token);
      return base;
    } catch (error) {
      if (controller.signal.aborted) return null;
      this.loadController = null;
      this.changed(false);
      throw error;
    }
  }

  cancelLoad(): void {
    if (!this.loadController) return;
    this.loadController.abort();
    this.loadController = null;
    this.traceEntry({ type: "load-abort" });
    this.changed(false);
  }

  /**
   * Switches the sender (a reconnect). Intents that were sent and never answered, or that waited
   * for a link, are resent with the same opid, in order; the provider applies an opid once.
   */
  setSender(sender: IntentSender | null): void {
    this.sender = sender;
    if (!sender) return;
    const resources = new Set<string>();
    for (const record of this.records) {
      if (record.phase === "sent" || record.phase === "waiting") {
        record.controller?.abort();
        record.controller = null;
        record.phase = "queued";
        record.attempt += 1;
        this.traceEntry({ type: "resend", opid: record.opid, kind: record.kind, resource: record.resource });
      }
      resources.add(record.resource);
    }
    this.changed(false);
    for (const resource of resources) this.pump(resource);
  }

  /** Cancels every pending intent (the page is closing); each reverts and its waiters resolve. */
  dispose(): void {
    this.loadController?.abort();
    this.loadController = null;
    for (const record of this.records.slice()) {
      record.controller?.abort();
      this.retire(record, { status: "superseded" });
    }
    this.listeners.clear();
  }

  // Internals.

  private supersedeOlder(kind: string, def: IntentKind<S>, resource: string): void {
    for (const record of this.records.slice()) {
      if (record.kind !== kind || record.resource !== resource) continue;
      if (record.phase === "queued" || record.phase === "waiting") {
        this.traceEntry({ type: "supersede", opid: record.opid, kind, resource });
        this.retire(record, { status: "superseded" });
      } else if (record.phase === "sent" && def.abortSuperseded) {
        this.traceEntry({ type: "supersede", opid: record.opid, kind, resource, detail: "aborted in flight" });
        record.controller?.abort();
        this.retire(record, { status: "superseded" });
      }
    }
  }

  /** Sends the head of `resource`'s queue when nothing on it is in flight. */
  private pump(resource: string): void {
    const sender = this.sender;
    if (!sender) return;
    for (const record of this.records) {
      if (record.resource !== resource) continue;
      if (record.phase === "acked") continue; // Answered; the next one may go.
      if (record.phase !== "queued") return; // In flight or waiting for a link.
      this.send(sender, record);
      return;
    }
  }

  private send(sender: IntentSender, record: IntentRecord): void {
    const def = record.def;
    const controller = new AbortController();
    record.controller = controller;
    record.phase = "sent";
    const attempt = record.attempt;
    this.traceEntry({
      type: attempt > 0 ? "resend" : "send",
      opid: record.opid,
      kind: record.kind,
      resource: record.resource,
    });
    this.meta = null;
    let promise: Promise<unknown>;
    try {
      const wire = def.wire ? def.wire(record.params) : record.params;
      promise = sender.call(def.op as string, wire, { signal: controller.signal, opid: record.opid });
    } catch (error) {
      promise = Promise.reject(error);
    }
    promise.then(
      (result) => this.answered(record, attempt, controller, { ok: true, result }),
      (error) => this.answered(record, attempt, controller, { ok: false, error: toProtocolError(error) }),
    );
  }

  private answered(
    record: IntentRecord,
    attempt: number,
    controller: AbortController,
    answer: { ok: true; result: unknown } | { ok: false; error: ProtocolError },
  ): void {
    // A stale answer: the intent was retired, superseded or resent since.
    if (this.byOpid.get(record.opid) !== record || record.attempt !== attempt || record.controller !== controller) {
      this.traceEntry({ type: "duplicate", opid: record.opid, kind: record.kind, detail: "stale answer" });
      return;
    }
    record.controller = null;
    if (answer.ok) {
      this.traceEntry({ type: "ok", opid: record.opid, kind: record.kind, resource: record.resource });
      if (record.def.confirm === "event") {
        record.phase = "acked";
        record.ackedBeforeLoad = this.loadSeq + 1;
        this.changed(false);
      } else {
        const def = record.def;
        this.base = (
          def.settle ? def.settle(this.base, record.params, answer.result) : def.apply(this.base, record.params)
        ) as S;
        this.retire(record, { status: "confirmed", result: answer.result });
        this.changed(true);
      }
      this.pump(record.resource);
      return;
    }
    const error = answer.error;
    this.traceEntry({
      type: "err",
      opid: record.opid,
      kind: record.kind,
      resource: record.resource,
      detail: error.code,
    });
    if (isLinkLoss(error)) {
      // Wait for `setSender`; the resend reuses the opid.
      record.phase = "waiting";
      this.changed(false);
      return;
    }
    this.refuse(record, error);
  }

  private refuse(record: IntentRecord, error: ProtocolError): void {
    const message = record.def.describeError ? record.def.describeError(error, record.params) : error.message;
    const refusal = this.intentError(record, error.code, message);
    this.retire(record, { status: "refused", error: refusal });
    this.pushError(refusal);
    for (const later of this.records.slice()) {
      if (later.resource !== record.resource || later.def.onPriorRefused !== "cancel") continue;
      if (later.phase !== "queued") continue;
      const cancelled = this.intentError(later, "cmux.intent.cancelled", `cancelled: ${message}`);
      this.traceEntry({ type: "cancel", opid: later.opid, kind: later.kind, resource: later.resource });
      this.retire(later, { status: "cancelled", error: cancelled });
      this.pushError(cancelled);
    }
    this.changed(true);
    this.pump(record.resource);
  }

  private intentError(record: IntentRecord, code: string, message: string): IntentError {
    return {
      opid: record.opid,
      kind: record.kind,
      op: record.def.op,
      resource: record.resource,
      code,
      message,
      params: record.params,
    };
  }

  private pushError(error: IntentError): void {
    this.errorList = [...this.errorList, error].slice(-this.errorLimit);
  }

  private retire(record: IntentRecord, outcome: IntentOutcome): void {
    const index = this.records.indexOf(record);
    if (index < 0) return;
    this.records.splice(index, 1);
    this.byOpid.delete(record.opid);
    this.settled.add(record.opid);
    if (this.settled.size > 1024) {
      const oldest = this.settled.values().next().value;
      if (oldest !== undefined) this.settled.delete(oldest);
    }
    this.dirty = true;
    this.meta = null;
    for (const waiter of record.waiters.splice(0)) waiter(outcome);
  }

  private changed(stateChanged: boolean): void {
    if (stateChanged) this.dirty = true;
    this.meta = null;
    for (const listener of Array.from(this.listeners)) listener();
  }

  private traceEntry(entry: Omit<IntentTrace, "at">): void {
    const full: IntentTrace = { at: now(), ...entry };
    this.traceBuffer.push(full);
    if (this.traceBuffer.length > this.traceLimit) this.traceBuffer.shift();
    this.onTrace?.(full);
  }
}

/** Declares an intent kind with its params type inferred (`defineIntent<State, Params>({...})`). */
export function defineIntent<S, P, R = unknown>(kind: IntentKind<S, P, R>): IntentKind<S, P, R> {
  return kind;
}
