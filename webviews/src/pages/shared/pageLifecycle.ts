// The page side of the hide-time save (plans/cmux-next/chrome-parity/p13-webui.md 3.C, task 088): a
// page saves its state when it hides, on `visibilitychange`, never when the host discards it. A hidden
// page may be frozen by then and cannot answer, so the host's discard asks the page for nothing. This is
// Chrome's Page Lifecycle rule: `visibilitychange` to hidden is the last event a page is sure to get
// before it is frozen or discarded (https://developer.chrome.com/docs/web-platform/page-lifecycle-api).
//
// The state goes to two places: sessionStorage, which an in-place Chromium discard keeps
// (`WebContents::Discard` keeps session storage), and the host (`PAGE_STATE_HANDLER`), which keeps it
// for a page whose engine page is closed (WebKit, or Chromium on an older fork). The host gives it back
// through sessionStorage before the page's scripts run, so `readPageState` is the one way back.

import { useCallback, useEffect, useRef, useSyncExternalStore } from "react";

/** The `window.webkit.messageHandlers` name the host takes the state on (PageWebView.pageStateHandler). */
export const PAGE_STATE_HANDLER = "cmuxPageState";
/** The sessionStorage key of the saved state. */
export const PAGE_STATE_KEY = "cmux.page.state";
/** The most a page may save, in bytes of UTF-8 (PageHideState.maxStateBytes). */
export const PAGE_STATE_MAX_BYTES = 64 * 1024;

/** Returns the page's state, as JSON can hold it. Called once per hide; keep it fast. */
export type PageStateSaver = () => unknown;

/** Where the save reads visibility and writes the state (the window by default, a fake in tests). */
export interface PageStateHost {
  readonly document: Pick<Document, "visibilityState" | "addEventListener" | "removeEventListener">;
  readonly storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | null;
  /** Posts the JSON to the host; null when the page has no host (a browser preview). */
  readonly post: ((json: string) => void) | null;
}

interface MessageHandlers {
  [name: string]: { postMessage(body: unknown): unknown } | undefined;
}

/** The window's host: its document, its sessionStorage and the host's state handler. */
export function windowPageStateHost(): PageStateHost {
  const handlers = (globalThis as { webkit?: { messageHandlers?: MessageHandlers } }).webkit?.messageHandlers;
  const handler = handlers?.[PAGE_STATE_HANDLER];
  let storage: Storage | null = null;
  try {
    storage = globalThis.sessionStorage ?? null;
  } catch {
    storage = null; // storage refused (a sandboxed document)
  }
  return {
    document,
    storage,
    post: handler ? (json) => void handler.postMessage(json) : null,
  };
}

/**
 * Saves `save()`'s state each time the page hides. One per document; returns the function that
 * stops it.
 *
 * ```ts
 * savePageStateOnHide(() => ({ scroll: list.scrollTop, query }));
 * const restored = readPageState<{ scroll: number; query: string }>();
 * ```
 */
export function savePageStateOnHide(save: PageStateSaver, host: PageStateHost = windowPageStateHost()): () => void {
  const onVisibility = () => {
    if (host.document.visibilityState === "hidden") writePageState(save(), host);
  };
  host.document.addEventListener("visibilitychange", onVisibility);
  return () => host.document.removeEventListener("visibilitychange", onVisibility);
}

/**
 * Writes `state` where a discard keeps it. A state over `PAGE_STATE_MAX_BYTES` is not kept: the
 * older one is cleared too, so the page never comes back to a state older than the one it had. The
 * host gets JSON `null` for no state (PageHideState.noStateText), never an oversized string.
 *
 * @returns Whether the state was kept.
 */
export function writePageState(state: unknown, host: PageStateHost): boolean {
  const json = JSON.stringify(state ?? null);
  const fits = new TextEncoder().encode(json).length <= PAGE_STATE_MAX_BYTES;
  try {
    if (fits) host.storage?.setItem(PAGE_STATE_KEY, json);
    else host.storage?.removeItem(PAGE_STATE_KEY);
  } catch {
    // Over the storage quota: the older state must not stay to be read back.
    clearStoredState(host);
  }
  host.post?.(fits ? json : "null");
  return fits;
}

/** Removes the stored state; a storage that refuses even that is left as it is. */
function clearStoredState(host: PageStateHost): void {
  try {
    host.storage?.removeItem(PAGE_STATE_KEY);
  } catch {
    // The storage refuses every write: nothing more the page can do.
  }
}

/** The state the page saved before it was discarded or reloaded; undefined when there is none. */
export function readPageState<T>(host: PageStateHost = windowPageStateHost()): T | undefined {
  let json: string | null = null;
  try {
    json = host.storage?.getItem(PAGE_STATE_KEY) ?? null;
  } catch {
    return undefined;
  }
  if (json === null) return undefined;
  try {
    const value = JSON.parse(json) as T | null;
    return value === null ? undefined : value;
  } catch {
    return undefined;
  }
}

// ---- Lifecycle state, timers and frames (task 033) ----
//
// Native tells the engine, never the page: a hidden page gets `visibilitychange`, a frozen one the
// standard `freeze` and, on thaw, `resume` (Chromium dispatches both from
// third_party/blink/renderer/core/page/page.cc SetPageFrozen, per the Page Lifecycle API; WebKit has
// no freeze event and stays hidden). There is no cmux lifecycle stream. Native guarantees the order:
// hidden before freeze, resume before visible. The engine is the one source of truth: a parked or
// preloaded page is hidden when native hides its view, as a background or
// prerendered Chrome page reads `visibilityState` "hidden" from its renderer.
//
// Timers and animation loops go through `startPageInterval` / `startPageAnimationFrame` (or their
// hooks): they run only while the page is active and start nothing while it is hidden or frozen.
// Showing the page again reads nothing: a poll waits for its next period, and only a clock that
// asks for `catchUpOnShow` ticks once on show.

/** Chrome's Page Lifecycle states that a page can observe; `discarded` never runs page code. */
export type PageLifecycleState = "active" | "hidden" | "frozen";

/** The part of `Document` the lifecycle reads. */
export interface LifecycleDocument {
  readonly visibilityState: string;
  addEventListener(type: string, listener: () => void): void;
  removeEventListener(type: string, listener: () => void): void;
}

/** The document events that change the state. */
const EVENTS = ["visibilitychange", "freeze", "resume"] as const;

/**
 * One document's lifecycle. Listeners are told only when the state changes; the document's
 * listeners exist only while someone observes.
 */
export class PageLifecycle {
  private frozen = false;
  private current: PageLifecycleState;
  /** One entry per `observe` call, so the same function observed twice is two subscriptions. */
  private readonly subscriptions = new Set<{ readonly listener: (state: PageLifecycleState) => void }>();

  constructor(private readonly doc: LifecycleDocument | undefined) {
    this.current = this.compute();
  }

  /** The state now. A page with no document (a test, a worker) is active. */
  state(): PageLifecycleState {
    return this.compute();
  }

  /** Calls `listener` on each change of state; returns the unsubscribe function. */
  observe(listener: (state: PageLifecycleState) => void): () => void {
    if (this.subscriptions.size === 0) {
      this.current = this.compute();
      for (const type of EVENTS) this.doc?.addEventListener(type, this.changed);
    }
    const subscription = { listener };
    this.subscriptions.add(subscription);
    return () => {
      if (!this.subscriptions.delete(subscription) || this.subscriptions.size > 0) return;
      for (const type of EVENTS) this.doc?.removeEventListener(type, this.changed);
    };
  }

  private compute(): PageLifecycleState {
    if (this.frozen) return "frozen";
    if (this.doc?.visibilityState === "hidden") return "hidden";
    return "active";
  }

  private readonly changed = (event?: { type?: string }): void => {
    // `freeze` and `resume` carry no state of their own on the document; remember which came last.
    if (event?.type === "freeze") this.frozen = true;
    else if (event?.type === "resume") this.frozen = false;
    const next = this.compute();
    if (next === this.current) return;
    this.current = next;
    for (const subscription of this.subscriptions) subscription.listener(next);
  };
}

const lifecycles = new WeakMap<object, PageLifecycle>();

/** The lifecycle of the current document of `target` (the page's global by default), made once
    per document. */
export function pageLifecycleFor(
  target: Record<string, unknown> = globalThis as unknown as Record<string, unknown>,
): PageLifecycle {
  const doc = target.document as LifecycleDocument | undefined;
  const key = doc ?? target;
  let lifecycle = lifecycles.get(key);
  if (!lifecycle) {
    lifecycle = new PageLifecycle(doc);
    lifecycles.set(key, lifecycle);
  }
  return lifecycle;
}

/**
 * Calls `listener` when the page becomes active, hidden or frozen. In the agent pane this counts as
 * a `visibilitychange` listener (scripts/cmux-next/check-switch-fetches.py): it must not read data.
 */
export function onPageLifecycleChange(
  listener: (state: PageLifecycleState) => void,
  lifecycle: PageLifecycle = pageLifecycleFor(),
): () => void {
  return lifecycle.observe(listener);
}

/** Whether the person can see the page. */
export function pageIsActive(lifecycle: PageLifecycle = pageLifecycleFor()): boolean {
  return lifecycle.state() === "active";
}

/** The timer seam: the page's own timers, or a fake clock in tests. */
export interface PageTimers {
  every(ms: number, callback: () => void): unknown;
  cancelEvery(handle: unknown): void;
  frame(callback: (time: number) => void): unknown;
  cancelFrame(handle: unknown): void;
}

export const browserTimers: PageTimers = {
  // wakeup-allow: bounded the page's one interval; startPageInterval arms it only while the page is active.
  every: (ms, callback) => setInterval(callback, ms),
  cancelEvery: (handle) => clearInterval(handle as ReturnType<typeof setInterval>),
  frame: (callback) => requestAnimationFrame(callback),
  cancelFrame: (handle) => cancelAnimationFrame(handle as number),
};

export interface PageIntervalOptions {
  lifecycle?: PageLifecycle;
  timers?: PageTimers;
  /**
   * Ticks once when the page shows again after a hide, for a clock whose text computes from a start
   * time. Never for a read: showing a page makes no fetch (in the agent pane,
   * check-switch-fetches.py counts it as a `visibilitychange` listener).
   */
  catchUpOnShow?: boolean;
}

/** Runs `callback` every `ms` while the page is active; returns the stop function. */
export function startPageInterval(callback: () => void, ms: number, options: PageIntervalOptions = {}): () => void {
  const lifecycle = options.lifecycle ?? pageLifecycleFor();
  const timers = options.timers ?? browserTimers;
  let handle: unknown;
  let running = false;
  let missed = false;
  const sync = (state: PageLifecycleState) => {
    if (state !== "active") {
      if (running) timers.cancelEvery(handle);
      running = false;
      handle = undefined;
      missed = true;
      return;
    }
    if (running) return;
    if (missed && options.catchUpOnShow) callback();
    missed = false;
    running = true;
    handle = timers.every(ms, callback);
  };
  const unobserve = lifecycle.observe(sync);
  sync(lifecycle.state());
  return () => {
    unobserve();
    if (running) timers.cancelEvery(handle);
    running = false;
  };
}

export interface PageAnimationFrameOptions {
  lifecycle?: PageLifecycle;
  timers?: PageTimers;
}

/**
 * Calls `callback` on every frame while the page is active, until it returns `false` or the stop
 * function runs. A hidden or frozen page has no frame scheduled; the loop resumes on show.
 */
export function startPageAnimationFrame(
  callback: (time: number) => boolean | void,
  options: PageAnimationFrameOptions = {},
): () => void {
  const lifecycle = options.lifecycle ?? pageLifecycleFor();
  const timers = options.timers ?? browserTimers;
  let handle: unknown;
  let scheduled = false;
  let done = false;
  const stop = () => {
    done = true;
    unobserve();
    if (scheduled) timers.cancelFrame(handle);
    scheduled = false;
  };
  const step = (time: number) => {
    scheduled = false;
    if (done) return;
    if (callback(time) === false) return stop();
    schedule();
  };
  const schedule = () => {
    if (done || scheduled || lifecycle.state() !== "active") return;
    scheduled = true;
    handle = timers.frame(step);
  };
  const unobserve = lifecycle.observe((state) => {
    if (state === "active") return schedule();
    if (scheduled) timers.cancelFrame(handle);
    scheduled = false;
  });
  schedule();
  return stop;
}

/**
 * The page's lifecycle state, re-rendering on each change. In the agent pane this counts as a
 * `visibilitychange` listener (scripts/cmux-next/check-switch-fetches.py): no read may key on it.
 */
export function usePageLifecycle(lifecycle: PageLifecycle = pageLifecycleFor()): PageLifecycleState {
  // Stable per lifecycle: a new `subscribe` makes React unsubscribe and subscribe again each render.
  const subscribe = useCallback((notify: () => void) => lifecycle.observe(notify), [lifecycle]);
  const snapshot = useCallback(() => lifecycle.state(), [lifecycle]);
  return useSyncExternalStore(subscribe, snapshot, serverSnapshot);
}

const serverSnapshot = (): PageLifecycleState => "active";

/** `startPageInterval` for a component: `ms` null stops it. The latest `callback` runs. */
export function usePageInterval(callback: () => void, ms: number | null, options: PageIntervalOptions = {}): void {
  const latest = useRef(callback);
  latest.current = callback;
  const { lifecycle, timers, catchUpOnShow } = options;
  useEffect(() => {
    if (ms === null) return;
    return startPageInterval(() => latest.current(), ms, { lifecycle, timers, catchUpOnShow });
  }, [ms, lifecycle, timers, catchUpOnShow]);
}

/** `startPageAnimationFrame` for a component while `running`. The latest `callback` runs. */
export function usePageAnimationFrame(
  callback: (time: number) => boolean | void,
  running: boolean,
  options: PageAnimationFrameOptions = {},
): void {
  const latest = useRef(callback);
  latest.current = callback;
  const { lifecycle, timers } = options;
  useEffect(() => {
    if (!running) return;
    return startPageAnimationFrame((time) => latest.current(time), { lifecycle, timers });
  }, [running, lifecycle, timers]);
}
