import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { layoutConversation, type AcpmuxRow } from "./model";

// A silent console: jsdom has no canvas, so text measurement logs and falls back to row estimates.
const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
/// Every ResizeObserver callback, so a test can report a viewport resize.
const resizeCallbacks: (() => void)[] = [];
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "ResizeObserver", "requestAnimationFrame", "cancelAnimationFrame", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  ResizeObserver: class { constructor(callback: () => void) { resizeCallbacks.push(callback); } observe() {} disconnect() {} },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react").then((react) => ({ act: react.act, createElement: react.createElement }));
const { createRoot } = await import("react-dom/client");
const { AcpmuxApp, VirtualTranscript } = await import("./App");
const { acpmuxPerf } = await import("./perf");

/// jsdom does no layout: give the transcript scroller a scriptable viewport and scroll offset.
function fakeViewport(size: { width: number; height: number }) {
  const prototype = dom.window.HTMLElement.prototype;
  const offsets = new WeakMap<object, number>();
  const isScroller = (node: HTMLElement) => node.classList.contains("acpmux-scroll");
  Object.defineProperty(prototype, "clientHeight", { configurable: true, get(this: HTMLElement) { return isScroller(this) ? size.height : 0; } });
  Object.defineProperty(prototype, "clientWidth", { configurable: true, get(this: HTMLElement) { return isScroller(this) ? size.width : 0; } });
  Object.defineProperty(prototype, "scrollTop", { configurable: true, get(this: HTMLElement) { return offsets.get(this) ?? 0; }, set(this: HTMLElement, value: number) { offsets.set(this, value); } });
  return () => { for (const key of ["clientHeight", "clientWidth", "scrollTop"]) delete (prototype as unknown as Record<string, unknown>)[key]; };
}

const rows: AcpmuxRow[] = Array.from({ length: 200 }, (_, index) => ({ id: `row-${index}`, version: 1, at: index, kind: index % 2 ? "assistant" : "user", text: `message ${index}` }));

describe("acpmux virtual transcript", () => {
  test("re-renders that keep rows and width reuse the conversation layout", async () => {
    let layouts = 0;
    const addLayout = acpmuxPerf.addLayout.bind(acpmuxPerf);
    acpmuxPerf.enabled = true;
    acpmuxPerf.addLayout = (ms: number) => { layouts += 1; addLayout(ms); };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const onToggleActivity = () => {};
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity, expanded: new Set<string>() })));
      const afterMount = layouts;
      expect(afterMount).toBeGreaterThan(0);
      // A scroll or an expansion toggle re-renders with the same rows and width.
      for (let pass = 0; pass < 5; pass += 1) {
        await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity, expanded: new Set<string>([`row-${pass}`]) })));
      }
      expect(layouts).toBe(afterMount);
      // New rows still lay out again.
      await act(async () => root.render(createElement(VirtualTranscript, { rows: [...rows, { id: "row-new", version: 1, at: 999, kind: "assistant", text: "new" }], onToggleActivity, expanded: new Set<string>() })));
      expect(layouts).toBeGreaterThan(afterMount);
    } finally {
      await act(async () => root.unmount());
      acpmuxPerf.addLayout = addLayout;
      acpmuxPerf.enabled = false;
    }
  });

  test("a scroll mounts the rows for the next frames in the scroll direction before it paints", async () => {
    const size = { width: 760, height: 600 };
    const restore = fakeViewport(size);
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() })));
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const totalHeight = parseFloat((dom.window.document.querySelector(".acpmux-spacer") as HTMLElement).style.height);
      expect(scroller.scrollTop).toBe(totalHeight - 600);
      const mountedTops = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")].map((row) => parseFloat(/translateY\((-?[\d.]+)px\)/.exec(row.style.transform)?.[1] ?? "NaN"));
      // A fling upward: each scroll event moves a viewport and a half. The scroll
      // event commits before the frame paints (no extra animation-frame hop), and
      // rows two steps ahead are already mounted when the next step lands.
      const step = 900;
      for (const top of [totalHeight - 600 - step, totalHeight - 600 - 2 * step]) {
        act(() => { scroller.scrollTop = top; scroller.dispatchEvent(new dom.window.Event("scroll")); });
        expect(Math.min(...mountedTops())).toBeLessThanOrEqual(Math.max(0, top - 2 * step));
        expect(Math.max(...mountedTops())).toBeGreaterThanOrEqual(top);
      }
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  test("a height-only shrink that makes fitting rows overflow opens at the latest row once", async () => {
    const size = { width: 760, height: 10_000 };
    const restore = fakeViewport(size);
    resizeCallbacks.length = 0;
    const root = createRoot(dom.window.document.getElementById("root")!);
    const fewRows = rows.slice(0, 6);
    const render = () => root.render(createElement(VirtualTranscript, { rows: fewRows, onToggleActivity: () => {}, expanded: new Set<string>() }));
    const resize = (height: number) => act(async () => { size.height = height; for (const callback of resizeCallbacks) callback(); });
    try {
      await act(async () => render());
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const totalHeight = parseFloat((dom.window.document.querySelector(".acpmux-spacer") as HTMLElement).style.height);
      expect(scroller.scrollTop).toBe(0);
      expect(totalHeight).toBeGreaterThan(40);
      await resize(40);
      expect(scroller.scrollTop).toBe(totalHeight - 40);
      // After that one jump a reader who scrolled up stays put through later resizes.
      scroller.scrollTop = 0;
      await resize(30);
      expect(scroller.scrollTop).toBe(0);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

describe("acpmux transcript accessibility", () => {
  /// VoiceOver read the transcript as loose text: no list to move through, no speaker per message,
  /// and a turn summary split into five fragments.
  test("the transcript is a feed of articles placed in the whole conversation", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const conversation: AcpmuxRow[] = [...rows, { id: "summary", version: 1, at: 999, kind: "turnSummary", durationMs: 3000, toolCount: 2 }];
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows: conversation, onToggleActivity: () => {}, expanded: new Set<string>() })));
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      expect(scroller.getAttribute("role")).toBe("feed");
      expect(scroller.getAttribute("aria-label")).toBe("Transcript");
      const articles = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")];
      expect(articles.length).toBeLessThan(conversation.length);
      for (const article of articles) expect(article.getAttribute("aria-setsize")).toBe(String(conversation.length));
      const last = articles.at(-1)!;
      expect(last.getAttribute("aria-posinset")).toBe(String(conversation.length));
      const mounted = articles.map((article) => ({ article, row: conversation[Number(article.getAttribute("aria-posinset")) - 1]! }));
      expect(mounted.find(({ row }) => row.kind === "user")?.article.getAttribute("aria-label")).toBe("You");
      expect(mounted.find(({ row }) => row.kind === "assistant")?.article.getAttribute("aria-label")).toBe("Agent");
      expect(last.hasAttribute("aria-label")).toBe(false);
      const summary = last.querySelector(".acpmux-summary")!;
      expect(summary.childNodes.length).toBe(1);
      expect(summary.textContent).toBe("Worked for 3s · 2 tool calls");
      // Older history still in acpmux: the conversation's size is unknown.
      await act(async () => root.render(createElement(VirtualTranscript, { rows: conversation, onToggleActivity: () => {}, expanded: new Set<string>(), canLoadOlder: true })));
      for (const article of dom.window.document.querySelectorAll(".acpmux-row")) expect(article.getAttribute("aria-setsize")).toBe("-1");
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// A blank line inside a user message rendered as an empty paragraph of two newlines, which a
  /// pre-wrap bubble drew as two extra lines the layout never counted.
  test("a blank line between paragraphs renders no paragraph of its own", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows: [{ id: "u", version: 1, at: 0, kind: "user", text: "first\n\nsecond" }], onToggleActivity: () => {}, expanded: new Set<string>() })));
      const paragraphs = [...dom.window.document.querySelectorAll(".acpmux-markdown > p")].map((node) => node.textContent);
      expect(paragraphs).toEqual(["first", "second"]);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// Rows are at most 760px wide (styles.css), but a wide pane laid them out at its whole width, so
  /// long messages wrapped onto more lines than their rows had room for.
  test("a wide pane lays rows out at the row's capped width", async () => {
    const restore = fakeViewport({ width: 1200, height: 600 });
    const root = createRoot(dom.window.document.getElementById("root")!);
    const long: AcpmuxRow = { id: "long", version: 1, at: 0, kind: "assistant", text: "word ".repeat(120).trim() };
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows: [long, { id: "next", version: 1, at: 1, kind: "assistant", text: "next" }], onToggleActivity: () => {}, expanded: new Set<string>() })));
      const next = dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")[1]!;
      expect(next.style.transform).toBe(`translateY(${layoutConversation([long], 760).heights[0]}px)`);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });
});

/// A seeded generator, so a failing shape reproduces.
function seeded(seed: number) {
  let state = seed >>> 0;
  return () => { state = (state * 1664525 + 1013904223) >>> 0; return state / 2 ** 32; };
}

/// Rows of every kind the transcript draws, in random markdown shapes.
function randomConversation(count: number, random: () => number): AcpmuxRow[] {
  const pieces = ["A sentence with `code` in it.", "## Heading\nText under it.", "- one\n- [ ] two\n- three", "```\nlet x = 1\n```", "> quoted", "Line one\nline two", "**bold** and [a link](https://example.com)"];
  return Array.from({ length: count }, (_, index) => {
    const pick = random();
    const text = Array.from({ length: 1 + Math.floor(random() * 4) }, () => pieces[Math.floor(random() * pieces.length)]!).join("\n\n");
    if (pick < 0.35) return { id: `r${index}`, version: 1, at: index, kind: "user", text };
    if (pick < 0.75) return { id: `r${index}`, version: 1, at: index, kind: "assistant", text };
    if (pick < 0.85) return { id: `r${index}`, version: 1, at: index, kind: "activity", toolCount: 2, items: [{ kind: "tool", text: "Read a file" }] } as AcpmuxRow;
    if (pick < 0.92) return { id: `r${index}`, version: 1, at: index, kind: "permission", permission: { permissionId: `p${index}`, title: "Allow this?", options: [{ id: "allow", name: "Allow" }] } } as AcpmuxRow;
    return { id: `r${index}`, version: 1, at: index, kind: "turnSummary", durationMs: 2000, toolCount: 1 };
  });
}

describe("acpmux measured rows", () => {
  /// The layout estimates a row's height before it draws, and some shapes always draw taller
  /// than any estimate (fonts, permission cards, expanded tool output). A row the page has drawn
  /// must be placed by its drawn height, so no row runs under the next one.
  test("drawn rows never overlap, whatever their shape", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const random = seeded(16476);
    const conversation = randomConversation(300, random);
    // jsdom does no layout: each row draws at a height the estimator can't know.
    const drawn = new Map(conversation.map((row) => [row.id, 30 + Math.round(random() * 220)]));
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const index = Number(this.getAttribute("aria-posinset")) - 1;
      const height = this.classList.contains("acpmux-row") ? drawn.get(conversation[index]?.id ?? "") ?? 0 : 0;
      return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() { return {}; } } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const overlaps = () => {
      const placed = [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .map((article) => ({ index: Number(article.getAttribute("aria-posinset")) - 1, top: Number(/translateY\(([-\d.]+)px\)/.exec(article.style.transform)?.[1]) }))
        .sort((a, b) => a.index - b.index);
      const found: string[] = [];
      for (let position = 1; position < placed.length; position += 1) {
        const above = placed[position - 1]!;
        const below = placed[position]!;
        if (below.index !== above.index + 1) continue;
        const bottom = above.top + drawn.get(conversation[above.index]!.id)!;
        if (bottom > below.top + 0.5) found.push(`${conversation[above.index]!.id} ends at ${bottom}, ${conversation[below.index]!.id} starts at ${below.top}`);
      }
      return found;
    };
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows: conversation, onToggleActivity: () => {}, expanded: new Set<string>() })));
      expect(overlaps()).toEqual([]);
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      for (const top of [0, 4000, 9000]) {
        await act(async () => { scroller.scrollTop = top; scroller.dispatchEvent(new dom.window.Event("scroll")); });
        expect(overlaps()).toEqual([]);
      }
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });
});

describe("acpmux renderer registry", () => {
  test("registering the same renderer again does not re-render the pane", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    let firstRenders = 0;
    let secondRenders = 0;
    const FirstChips = () => { firstRenders += 1; return null; };
    const SecondChips = () => { secondRenders += 1; return null; };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () => host.cmuxAcpmuxRegistry!.register("composerChips", FirstChips as never));
      const afterRegister = firstRenders;
      expect(afterRegister).toBeGreaterThan(0);
      await act(async () => host.cmuxAcpmuxRegistry!.register("composerChips", FirstChips as never));
      expect(firstRenders).toBe(afterRegister);
      await act(async () => host.cmuxAcpmuxRegistry!.register("composerChips", SecondChips as never));
      expect(secondRenders).toBeGreaterThan(0);
    } finally {
      await act(async () => root.unmount());
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });
});

describe("acpmux host handshake", () => {
  /// A loopback acpmux that answers the open handshake and can drop the socket.
  class FakeSocket {
    static OPEN = 1;
    static made: FakeSocket[] = [];
    readyState = 0;
    onopen?: () => void;
    onerror?: () => void;
    onclose?: () => void;
    onmessage?: (message: { data: string }) => void;
    constructor(readonly url: URL) {
      FakeSocket.made.push(this);
      queueMicrotask(() => { this.readyState = 1; this.onopen?.(); });
    }
    send(raw: string) {
      const { id, method } = JSON.parse(raw) as { id: number; method: string };
      const result = method === "_acpmux/watch" ? { sessions: [] } : {};
      queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ id, result }) }));
    }
    close() { this.readyState = 3; }
    drop() { this.readyState = 3; this.onclose?.(); }
  }

  /// After losing the daemon the page asks Swift again; that retry restarted a daemon the user had stopped.
  test("a page that lost its daemon asks for a handshake that does not start one", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Record<string, unknown>;
    const realSocket = globals.WebSocket;
    const asked: Record<string, unknown>[] = [];
    globals.WebSocket = FakeSocket;
    host.webkit = { messageHandlers: { agentSession: { postMessage(message: { method: string; params: Record<string, unknown> }) {
      if (message.method !== "ready") return Promise.resolve({ ok: true, value: null });
      asked.push(message.params);
      return Promise.resolve({ ok: true, value: { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:4100/acp", token: "t" } });
    } } } };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      for (let tries = 0; tries < 100 && FakeSocket.made.length === 0; tries += 1) await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
      expect(asked).toEqual([{}]);
      await act(async () => FakeSocket.made[0]!.drop());
      for (let tries = 0; tries < 100 && asked.length < 2; tries += 1) await act(() => new Promise((resolve) => setTimeout(resolve, 20)));
      expect(asked[1]).toEqual({ reconnect: true });
    } finally {
      await act(async () => root.unmount());
      globals.WebSocket = realSocket;
      delete host.webkit;
      delete host.cmuxAcpmuxRegistry;
    }
  });
});
