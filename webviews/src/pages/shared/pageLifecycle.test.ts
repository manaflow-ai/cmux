// A page saves its state when it hides (visibilitychange), never when the host discards it: a frozen
// page cannot answer the host (p13-webui-088).
//
// The page lifecycle (plans/cmux-next/chrome-parity/p13-webui.md 3.C, task 033): pages follow
// `document.visibilityState` and the standard `freeze`/`resume` events, with no native stream. No
// timer or animation frame starts while the page is hidden, frozen or parked, and a show or resume
// sends nothing to the host.
import { afterEach, describe, expect, test } from "bun:test";
import { act, createElement } from "react";
import { BridgePageClient, CLAIM_OP, type ReplyHandler } from "./pageClient";
import {
  PAGE_STATE_KEY,
  PAGE_STATE_MAX_BYTES,
  PARKED_NAME,
  PageLifecycle,
  type LifecycleDocument,
  type PageStateHost,
  type PageTimers,
  pageLifecycleFor,
  readPageState,
  savePageStateOnHide,
  startPageAnimationFrame,
  startPageInterval,
  usePageAnimationFrame,
  usePageInterval,
  usePageLifecycle,
  writePageState,
} from "./pageLifecycle";

type Listener = () => void;

/** A document whose visibility the test sets, a Map as sessionStorage and a log of host posts. */
function makeHost(): {
  host: PageStateHost;
  posts: string[];
  stored: Map<string, string>;
  setVisibility(state: DocumentVisibilityState): void;
  listenerCount(): number;
} {
  let visibility: DocumentVisibilityState = "visible";
  const listeners = new Set<Listener>();
  const stored = new Map<string, string>();
  const posts: string[] = [];
  const document = {
    get visibilityState() {
      return visibility;
    },
    addEventListener: (type: string, listener: Listener) => {
      if (type === "visibilitychange") listeners.add(listener);
    },
    removeEventListener: (type: string, listener: Listener) => {
      if (type === "visibilitychange") listeners.delete(listener);
    },
  } as unknown as PageStateHost["document"];
  const storage = {
    getItem: (key: string) => stored.get(key) ?? null,
    setItem: (key: string, value: string) => void stored.set(key, value),
    removeItem: (key: string) => void stored.delete(key),
  };
  return {
    host: { document, storage, post: (json) => posts.push(json) },
    posts,
    stored,
    setVisibility(state) {
      visibility = state;
      for (const listener of listeners) listener();
    },
    listenerCount: () => listeners.size,
  };
}

describe("pageLifecycle hide-time save", () => {
  test("the state is saved on the hide, not before and not on the show", () => {
    const page = makeHost();
    let scroll = 10;
    let saves = 0;
    savePageStateOnHide(() => {
      saves += 1;
      return { scroll };
    }, page.host);
    expect(saves).toBe(0);
    scroll = 120;
    page.setVisibility("hidden");
    expect(saves).toBe(1);
    expect(page.stored.get(PAGE_STATE_KEY)).toBe('{"scroll":120}');
    expect(page.posts).toEqual(['{"scroll":120}']);
    page.setVisibility("visible");
    expect(saves).toBe(1);
    expect(readPageState<{ scroll: number }>(page.host)).toEqual({ scroll: 120 });
  });

  test("the stop function removes the one listener", () => {
    const page = makeHost();
    const stop = savePageStateOnHide(() => ({}), page.host);
    expect(page.listenerCount()).toBe(1);
    stop();
    expect(page.listenerCount()).toBe(0);
    page.setVisibility("hidden");
    expect(page.posts).toEqual([]);
  });

  test("an oversized state clears the older one everywhere", () => {
    const page = makeHost();
    expect(writePageState({ query: "a" }, page.host)).toBe(true);
    expect(writePageState({ text: "x".repeat(PAGE_STATE_MAX_BYTES) }, page.host)).toBe(false);
    expect(page.stored.has(PAGE_STATE_KEY)).toBe(false);
    expect(page.posts).toEqual(['{"query":"a"}', "null"]);
    expect(readPageState(page.host)).toBeUndefined();
  });

  test("the limit counts UTF-8 bytes, not UTF-16 units", () => {
    const page = makeHost();
    // Each "é" is one UTF-16 unit and two UTF-8 bytes: about 40 K units is about 80 KB.
    expect(writePageState("é".repeat(40_000), page.host)).toBe(false);
  });

  test("a page with no host still saves to sessionStorage", () => {
    const page = makeHost();
    const host: PageStateHost = { ...page.host, post: null };
    expect(writePageState([1, 2], host)).toBe(true);
    expect(readPageState<number[]>(host)).toEqual([1, 2]);
  });

  test("a write the storage refuses leaves no older state to read back", () => {
    const page = makeHost();
    expect(writePageState({ scroll: 10 }, page.host)).toBe(true);
    const full: PageStateHost = {
      ...page.host,
      storage: {
        getItem: (key) => page.stored.get(key) ?? null,
        setItem: () => {
          throw new DOMException("quota", "QuotaExceededError");
        },
        removeItem: (key) => void page.stored.delete(key),
      },
    };
    expect(writePageState({ scroll: 120 }, full)).toBe(true);
    expect(readPageState(full)).toBeUndefined();
    expect(page.posts).toEqual(['{"scroll":10}', '{"scroll":120}']);
  });

  test("an unreadable saved state reads as none", () => {
    const page = makeHost();
    page.stored.set(PAGE_STATE_KEY, "{not json");
    expect(readPageState(page.host)).toBeUndefined();
  });
});

/** A document whose visibility the test sets and whose events it dispatches. */
class FakeDocument implements LifecycleDocument {
  visibilityState = "visible";
  private readonly listeners = new Map<string, Set<(event: { type: string }) => void>>();

  addEventListener(type: string, listener: (event: { type: string }) => void): void {
    const set = this.listeners.get(type) ?? new Set();
    set.add(listener);
    this.listeners.set(type, set);
  }

  removeEventListener(type: string, listener: (event: { type: string }) => void): void {
    this.listeners.get(type)?.delete(listener);
  }

  listenerCount(): number {
    let count = 0;
    for (const set of this.listeners.values()) count += set.size;
    return count;
  }

  dispatch(type: string): void {
    for (const listener of this.listeners.get(type) ?? []) listener({ type });
  }

  hide(): void {
    this.visibilityState = "hidden";
    this.dispatch("visibilitychange");
  }

  show(): void {
    this.visibilityState = "visible";
    this.dispatch("visibilitychange");
  }

  /** Native's order: hidden, then frozen. */
  freeze(): void {
    if (this.visibilityState !== "hidden") this.hide();
    this.dispatch("freeze");
  }

  /** Native's order: resumed, then visible. */
  thawAndShow(): void {
    this.dispatch("resume");
    this.show();
  }
}

/** A fake clock: intervals and frames run only when the test advances them. */
class FakeTimers implements PageTimers {
  started = 0;
  framesRequested = 0;
  private next = 1;
  private readonly intervals = new Map<number, { ms: number; callback: () => void; due: number }>();
  private readonly frames = new Map<number, (time: number) => void>();
  private now = 0;

  every(ms: number, callback: () => void): unknown {
    this.started += 1;
    const id = this.next++;
    this.intervals.set(id, { ms, callback, due: this.now + ms });
    return id;
  }

  cancelEvery(handle: unknown): void {
    this.intervals.delete(handle as number);
  }

  frame(callback: (time: number) => void): unknown {
    this.framesRequested += 1;
    const id = this.next++;
    this.frames.set(id, callback);
    return id;
  }

  cancelFrame(handle: unknown): void {
    this.frames.delete(handle as number);
  }

  get live(): number {
    return this.intervals.size;
  }

  get pendingFrames(): number {
    return this.frames.size;
  }

  advance(ms: number): void {
    const end = this.now + ms;
    for (;;) {
      let soonest: { ms: number; callback: () => void; due: number } | undefined;
      for (const interval of this.intervals.values())
        if (interval.due <= end && (!soonest || interval.due < soonest.due)) soonest = interval;
      if (!soonest) break;
      this.now = soonest.due;
      soonest.due += soonest.ms;
      soonest.callback();
    }
    this.now = end;
  }

  runFrame(): void {
    const frames = [...this.frames.values()];
    this.frames.clear();
    for (const frame of frames) frame(this.now);
  }
}

describe("PageLifecycle", () => {
  test("follows visibility, freeze and resume, telling observers only of changes", () => {
    const doc = new FakeDocument();
    const lifecycle = new PageLifecycle(doc);
    const seen: string[] = [];
    const stop = lifecycle.observe((state) => seen.push(state));
    expect(lifecycle.state()).toBe("active");
    doc.hide();
    doc.dispatch("visibilitychange");
    doc.freeze();
    doc.thawAndShow();
    expect(seen).toEqual(["hidden", "frozen", "hidden", "active"]);
    stop();
    expect(doc.listenerCount()).toBe(0);
  });

  test("a page with no document is active", () => {
    expect(new PageLifecycle(undefined).state()).toBe("active");
  });

  test("a parked document is hidden until its claim, even while the engine shows it", () => {
    const doc = new FakeDocument();
    const lifecycle = new PageLifecycle(doc, true);
    const seen: string[] = [];
    lifecycle.observe((state) => seen.push(state));
    expect(lifecycle.state()).toBe("hidden");
    lifecycle.claimed();
    expect(seen).toEqual(["active"]);
  });

  test("one lifecycle per page global, parked from the host's flag", () => {
    const doc = new FakeDocument();
    const target: Record<string, unknown> = { document: doc, [PARKED_NAME]: true };
    expect(pageLifecycleFor(target)).toBe(pageLifecycleFor(target));
    expect(pageLifecycleFor(target).state()).toBe("hidden");
  });
});

describe("startPageInterval", () => {
  test("starts no timer while hidden, runs while shown, stops on hide", () => {
    const doc = new FakeDocument();
    doc.hide();
    const lifecycle = new PageLifecycle(doc);
    const timers = new FakeTimers();
    let ticks = 0;
    const stop = startPageInterval(() => ticks++, 1000, { lifecycle, timers });
    timers.advance(60_000);
    expect(timers.started).toBe(0);
    expect(ticks).toBe(0);

    doc.show();
    expect(ticks).toBe(0);
    timers.advance(3000);
    expect(ticks).toBe(3);

    doc.hide();
    expect(timers.live).toBe(0);
    timers.advance(60_000);
    expect(ticks).toBe(3);
    stop();
  });

  test("a frozen page starts nothing; resume alone does not restart it", () => {
    const doc = new FakeDocument();
    const lifecycle = new PageLifecycle(doc);
    const timers = new FakeTimers();
    let ticks = 0;
    const stop = startPageInterval(() => ticks++, 1000, { lifecycle, timers });
    expect(timers.live).toBe(1);
    doc.freeze();
    expect(timers.live).toBe(0);
    doc.dispatch("resume");
    expect(timers.live).toBe(0);
    doc.show();
    expect(timers.live).toBe(1);
    expect(ticks).toBe(0);
    stop();
    expect(timers.live).toBe(0);
    expect(doc.listenerCount()).toBe(0);
  });

  test("a clock catches up once on show; a poll does not", () => {
    const doc = new FakeDocument();
    const lifecycle = new PageLifecycle(doc);
    const timers = new FakeTimers();
    let clock = 0;
    let poll = 0;
    startPageInterval(() => clock++, 1000, { lifecycle, timers, catchUpOnShow: true });
    startPageInterval(() => poll++, 1000, { lifecycle, timers });
    expect(clock).toBe(0);
    doc.hide();
    doc.show();
    expect(clock).toBe(1);
    expect(poll).toBe(0);
  });

  test("a clock started hidden catches up on its first show", () => {
    const doc = new FakeDocument();
    doc.hide();
    const lifecycle = new PageLifecycle(doc);
    const timers = new FakeTimers();
    let clock = 0;
    startPageInterval(() => clock++, 1000, { lifecycle, timers, catchUpOnShow: true });
    doc.show();
    expect(clock).toBe(1);
  });
});

describe("startPageAnimationFrame", () => {
  test("schedules no frame while hidden and resumes on show", () => {
    const doc = new FakeDocument();
    const lifecycle = new PageLifecycle(doc);
    const timers = new FakeTimers();
    let frames = 0;
    const stop = startPageAnimationFrame(() => void frames++, { lifecycle, timers });
    timers.runFrame();
    timers.runFrame();
    expect(frames).toBe(2);
    doc.hide();
    expect(timers.pendingFrames).toBe(0);
    const requested = timers.framesRequested;
    timers.runFrame();
    expect(timers.framesRequested).toBe(requested);
    doc.show();
    expect(timers.pendingFrames).toBe(1);
    timers.runFrame();
    expect(frames).toBe(3);
    stop();
    expect(timers.pendingFrames).toBe(0);
    expect(doc.listenerCount()).toBe(0);
  });

  test("a loop that returns false ends and stops following the lifecycle", () => {
    const doc = new FakeDocument();
    const lifecycle = new PageLifecycle(doc);
    const timers = new FakeTimers();
    let frames = 0;
    startPageAnimationFrame(() => ++frames < 2, { lifecycle, timers });
    timers.runFrame();
    timers.runFrame();
    expect(frames).toBe(2);
    expect(timers.pendingFrames).toBe(0);
    expect(doc.listenerCount()).toBe(0);
    doc.hide();
    doc.show();
    expect(timers.pendingFrames).toBe(0);
  });
});

describe("the page client and the lifecycle", () => {
  test("hide, freeze, resume and show send nothing to the host", async () => {
    const doc = new FakeDocument();
    const posts: unknown[] = [];
    const handler: ReplyHandler = {
      postMessage: async (body) => {
        posts.push(body);
        const envelope = body as { t: string; id: number };
        return envelope.t === "sub" ? { t: "ok", id: envelope.id, value: { sub: 1 } } : { t: "ok", id: envelope.id };
      },
    };
    const target: Record<string, unknown> = { document: doc };
    const client = new BridgePageClient(handler, target);
    await client.subscribe("cmux.test.rows", () => undefined);
    const before = posts.length;
    const seen: string[] = [];
    pageLifecycleFor(target).observe((state) => seen.push(state));
    doc.freeze();
    doc.thawAndShow();
    expect(seen).toEqual(["hidden", "frozen", "hidden", "active"]);
    expect(posts.length).toBe(before);
  });

  test("the claim of a parked document makes its lifecycle active", async () => {
    const doc = new FakeDocument();
    const posts: unknown[] = [];
    const handler: ReplyHandler = {
      postMessage: async (body) => {
        posts.push(body);
        return null;
      },
    };
    const target: Record<string, unknown> = { document: doc, [PARKED_NAME]: true };
    const client = new BridgePageClient(handler, target);
    const timers = new FakeTimers();
    startPageInterval(() => undefined, 1000, { lifecycle: pageLifecycleFor(target), timers });
    expect(timers.started).toBe(0);
    client.receive({ t: "call", id: 1, op: CLAIM_OP, params: {} });
    await Promise.resolve();
    expect(pageLifecycleFor(target).state()).toBe("active");
    expect(timers.live).toBe(1);
  });
});

describe("hooks", () => {
  const scope = globalThis as Record<string, unknown>;
  const saved = new Map<string, unknown>();
  let unmount: (() => void) | undefined;

  afterEach(async () => {
    // React's scheduler reads `window` after a commit: unmount inside act, before the DOM goes.
    if (unmount) await act(async () => unmount?.());
    unmount = undefined;
    for (const [key, value] of saved) {
      if (value === undefined) delete scope[key];
      else scope[key] = value;
    }
    saved.clear();
  });

  async function render(element: ReturnType<typeof createElement>): Promise<void> {
    const { JSDOM } = await import("jsdom");
    const dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
      url: "http://localhost/",
    });
    for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
    Object.assign(scope, {
      window: dom.window,
      document: dom.window.document,
      navigator: dom.window.navigator,
      IS_REACT_ACT_ENVIRONMENT: true,
    });
    const { createRoot } = await import("react-dom/client");
    const root = createRoot(dom.window.document.getElementById("root") as unknown as Element);
    await act(async () => root.render(element));
    unmount = () => root.unmount();
  }

  test("usePageInterval and usePageAnimationFrame run only while the page shows", async () => {
    const doc = new FakeDocument();
    doc.hide();
    const lifecycle = new PageLifecycle(doc);
    const timers = new FakeTimers();
    const states: string[] = [];
    let ticks = 0;
    let frames = 0;
    function Probe() {
      states.push(usePageLifecycle(lifecycle));
      usePageInterval(() => ticks++, 1000, { lifecycle, timers });
      usePageAnimationFrame(() => void frames++, true, { lifecycle, timers });
      return null;
    }
    await render(createElement(Probe));
    timers.advance(10_000);
    timers.runFrame();
    expect(timers.started).toBe(0);
    expect(timers.framesRequested).toBe(0);

    await act(async () => doc.show());
    timers.advance(2000);
    timers.runFrame();
    expect(ticks).toBe(2);
    expect(frames).toBe(1);
    expect(states.at(0)).toBe("hidden");
    expect(states.at(-1)).toBe("active");

    await act(async () => doc.hide());
    expect(timers.live).toBe(0);
    expect(timers.pendingFrames).toBe(0);
  });
});
