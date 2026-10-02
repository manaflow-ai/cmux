import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { layoutConversation, type AcpmuxRow } from "./model";

// A silent console: jsdom has no canvas, so text measurement logs and falls back to row estimates.
const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
/// Every ResizeObserver callback, so a test can report a viewport resize.
const resizeCallbacks: (() => void)[] = [];
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "customElements", "Node", "IntersectionObserver", "ResizeObserver", "requestAnimationFrame", "cancelAnimationFrame", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  IntersectionObserver: class { observe() {} unobserve() {} disconnect() {} },
  ResizeObserver: class { constructor(callback: () => void) { resizeCallbacks.push(callback); } observe() {} unobserve() {} disconnect() {} },
  requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(0), 0) as unknown as number,
  cancelAnimationFrame: (handle: number) => clearTimeout(handle),
  IS_REACT_ACT_ENVIRONMENT: true,
});
// The changes view renders @pierre/diffs and @pierre/trees web components, which reach for
// DOM classes (HTMLTemplateElement, SVGElement, ...) by their global names.
const domClasses = Object.getOwnPropertyNames(dom.window).filter((key) => /^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in globals));
for (const key of domClasses) globals[key] = (dom.window as unknown as Record<string, unknown>)[key];
afterAll(() => { Object.assign(globals, saved); for (const key of domClasses) delete globals[key]; });

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
  // Like a browser, the offset clamps to the content once it lays out again.
  const contentHeight = (node: HTMLElement) => parseFloat(node.querySelector<HTMLElement>(".acpmux-spacer")?.style.height || "0");
  const maximum = (node: HTMLElement) => Math.max(0, contentHeight(node) - size.height);
  Object.defineProperty(prototype, "scrollHeight", { configurable: true, get(this: HTMLElement) { return isScroller(this) ? Math.max(contentHeight(this), size.height) : 0; } });
  Object.defineProperty(prototype, "scrollTop", { configurable: true, get(this: HTMLElement) { const offset = Math.min(offsets.get(this) ?? 0, maximum(this)); offsets.set(this, offset); return offset; }, set(this: HTMLElement, value: number) { offsets.set(this, Math.max(0, Math.min(value, maximum(this)))); } });
  return () => { for (const key of ["clientHeight", "clientWidth", "scrollHeight", "scrollTop"]) delete (prototype as unknown as Record<string, unknown>)[key]; };
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
      // Opened at the latest row, it stays there as the rows settle to their drawn heights.
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 600);
      for (const top of [0, 4000, 9000]) {
        await act(async () => { scroller.scrollTop = top; scroller.dispatchEvent(new dom.window.Event("scroll")); });
        expect(overlaps()).toEqual([]);
      }
      // A row above the viewport that grows leaves the row at the viewport's top where it is.
      const placed = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-row")].map((article) => ({ article, index: Number(article.getAttribute("aria-posinset")) - 1, top: Number(/translateY\(([-\d.]+)px\)/.exec(article.style.transform)?.[1]) }));
      const atTop = () => placed().filter((row) => row.top <= scroller.scrollTop).sort((a, b) => b.top - a.top)[0]!;
      const anchor = atTop();
      const offset = scroller.scrollTop - anchor.top;
      const above = placed().filter((row) => row.index < anchor.index).sort((a, b) => a.index - b.index)[0]!;
      drawn.set(conversation[above.index]!.id, drawn.get(conversation[above.index]!.id)! + 100);
      await act(async () => { for (const callback of resizeCallbacks) (callback as (entries: { target: Element }[]) => void)([{ target: above.article }]); });
      expect(atTop().index).toBe(anchor.index);
      expect(scroller.scrollTop - atTop().top).toBe(offset);
      expect(overlaps()).toEqual([]);
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });
  /// A fling mounts rows that have not drawn yet, and each one reports its height once.
  /// Placing it must not measure every row of the conversation again.
  test("a row's drawn height re-places the rows without measuring them again", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    let measures = 0;
    const Plain = Object.assign(() => null, { measure: () => { measures += 1; return 50; } });
    const registry = { user: Plain, assistant: Plain } as never;
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    let drawnHeight = 0;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const height = this.classList.contains("acpmux-row") && this.getAttribute("aria-posinset") === "200" ? drawnHeight : 0;
      return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() { return {}; } } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>(), registry })));
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      const estimated = parseFloat(spacer.style.height);
      const afterOpen = measures;
      drawnHeight = 90;
      const latest = dom.window.document.querySelector<HTMLElement>('.acpmux-row[aria-posinset="200"]')!;
      await act(async () => { for (const callback of resizeCallbacks) (callback as (entries: { target: Element }[]) => void)([{ target: latest }]); });
      expect(parseFloat(spacer.style.height)).toBe(estimated + 40);
      expect(measures).toBe(afterOpen);
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });

  /// A permission card or a taller composer shortens the viewport without moving the offset,
  /// so the latest row's end drops below the fold unless the transcript follows it.
  test("at the latest row, a shorter viewport keeps the latest row in view", async () => {
    const size = { width: 760, height: 600 };
    const restore = fakeViewport(size);
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() })));
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 600);
      size.height = 400;
      await act(async () => { for (const callback of resizeCallbacks) callback(); });
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 400);
    } finally {
      await act(async () => root.unmount());
      restore();
    }
  });

  /// A reader near the end scrolls up, and before that scroll's event a row below draws shorter.
  /// The offset lands just under the new end without the browser clamping it, so the reader stays.
  test("a small scroll-up at the latest row survives a row below drawing shorter", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    let lastHeight = 120;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const height = this.classList.contains("acpmux-row") && this.getAttribute("aria-posinset") === "200" ? lastHeight : 0;
      return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() { return {}; } } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    const reportLatest = async () => {
      const latest = dom.window.document.querySelector<HTMLElement>('.acpmux-row[aria-posinset="200"]')!;
      await act(async () => { for (const callback of resizeCallbacks) (callback as (entries: { target: Element }[]) => void)([{ target: latest }]); });
    };
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows, onToggleActivity: () => {}, expanded: new Set<string>() })));
      await reportLatest();
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      const end = parseFloat(spacer.style.height) - 600;
      expect(scroller.scrollTop).toBe(end);
      // Up by 10.75px; the latest row then draws 10px shorter, so the new end is 0.75px below the reader.
      scroller.scrollTop = end - 10.75;
      lastHeight -= 10;
      await reportLatest();
      expect(parseFloat(spacer.style.height) - 600).toBe(end - 10);
      expect(scroller.scrollTop).toBe(end - 10.75);
    } finally {
      await act(async () => root.unmount());
      prototype.getBoundingClientRect = original;
      restore();
    }
  });

  /// Rows that draw shorter than estimated shrink the content under a viewport at the latest row,
  /// and the browser clamps the offset before the layout effect sees it.
  test("opened at the latest row, it stays there as rows draw shorter than estimated", async () => {
    const restore = fakeViewport({ width: 760, height: 600 });
    const conversation: AcpmuxRow[] = Array.from({ length: 300 }, (_, index) => ({ id: `long-${index}`, version: 1, at: index, kind: "assistant", text: `${"word ".repeat(200)}${index}` }));
    const prototype = dom.window.HTMLElement.prototype;
    const original = prototype.getBoundingClientRect;
    prototype.getBoundingClientRect = function (this: HTMLElement) {
      const height = this.classList.contains("acpmux-row") ? 40 : 0;
      return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() { return {}; } } as DOMRect;
    };
    const root = createRoot(dom.window.document.getElementById("root")!);
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows: conversation, onToggleActivity: () => {}, expanded: new Set<string>() })));
      const scroller = dom.window.document.querySelector(".acpmux-scroll") as HTMLElement;
      const spacer = dom.window.document.querySelector(".acpmux-spacer") as HTMLElement;
      for (let frame = 0; frame < 3; frame += 1) await act(async () => { scroller.dispatchEvent(new dom.window.Event("scroll")); });
      expect(scroller.scrollTop).toBe(parseFloat(spacer.style.height) - 600);
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

  /// The model picker reads the catalog through TanStack Query and keeps the old one across a reconnect.
  test("the model picker loads each daemon's catalog and keeps the last one while reconnecting", async () => {
    class CatalogSocket extends FakeSocket {
      static catalogs = [["m1"], ["m1", "m2"]];
      static holdHarnesses = false;
      static held: (() => void)[] = [];
      override send(raw: string) {
        const { id, method } = JSON.parse(raw) as { id: number; method: string };
        const models = CatalogSocket.catalogs[FakeSocket.made.indexOf(this)] ?? [];
        const result =
          method === "_acpmux/watch" ? { sessions: [{ sessionId: "s" }] }
          : method === "_acpmux/attach" ? { session: { sessionId: "s", harness: "codex", model: "m1" }, events: [] }
          : method === "_acpmux/harnesses" ? { harnesses: [{ id: "codex", name: "Codex", models: models.map((model) => ({ id: model })) }] }
          : {};
        const reply = () => this.onmessage?.({ data: JSON.stringify({ id, result }) });
        if (method === "_acpmux/harnesses" && CatalogSocket.holdHarnesses) CatalogSocket.held.push(reply);
        else queueMicrotask(reply);
      }
    }
    FakeSocket.made = [];
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Record<string, unknown>;
    const realSocket = globals.WebSocket;
    globals.WebSocket = CatalogSocket;
    host.webkit = { messageHandlers: { agentSession: { postMessage(message: { method: string }) {
      if (message.method !== "ready") return Promise.resolve({ ok: true, value: null });
      return Promise.resolve({ ok: true, value: { protocolVersion: 1, transport: "acpmux-websocket", endpoint: "ws://127.0.0.1:4100/acp", token: "t", sessionId: "s" } });
    } } } };
    const models = () => [...dom.window.document.querySelectorAll(".acpmux-model option")].map((option) => option.getAttribute("value"));
    const waitFor = async (done: () => boolean) => { for (let tries = 0; tries < 100 && !done(); tries += 1) await act(() => new Promise((resolve) => setTimeout(resolve, 10))); };
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await waitFor(() => models().length > 0);
      expect(models()).toEqual(["m1"]);
      CatalogSocket.holdHarnesses = true;
      await act(async () => FakeSocket.made[0]!.drop());
      await waitFor(() => CatalogSocket.held.length > 0);
      expect(FakeSocket.made.length).toBe(2);
      expect(models()).toEqual(["m1"]);
      await act(async () => CatalogSocket.held.splice(0).forEach((reply) => reply()));
      await waitFor(() => models().length === 2);
      expect(models()).toEqual(["m1", "m2"]);
    } finally {
      await act(async () => root.unmount());
      globals.WebSocket = realSocket;
      delete host.webkit;
      delete host.cmuxAcpmuxRegistry;
      FakeSocket.made = [];
    }
  });

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

describe("acpmux turn diff", () => {
  test("Review changes opens the turn's files, and the layout toggles between unified and split", async () => {
    const root = createRoot(dom.window.document.getElementById("root")!);
    const host = dom.window as unknown as Window;
    const document = dom.window.document;
    const diffRow: AcpmuxRow = { id: "activity-2", version: 1, at: 2, kind: "activity", toolCount: 2, items: [
      { kind: "tool", text: "Edit main.ts", tool: { id: "t1", title: "Edit main.ts", kind: "edit", status: "completed", diffs: [{ path: "/repo/src/main.ts", oldText: "a\nb\nc\n", newText: "a\nB\nc\n" }] } },
      { kind: "tool", text: "Write notes.md", tool: { id: "t2", title: "Write notes.md", kind: "edit", status: "completed", diffs: [{ path: "/repo/notes.md", newText: "hello\n" }] } },
    ] };
    const turn: AcpmuxRow[] = [{ id: "user-1", version: 1, at: 1, kind: "user", text: "fix it" }, diffRow, { id: "assistant-3", version: 1, at: 3, kind: "assistant", text: "done" }];
    try {
      await act(async () => root.render(createElement(AcpmuxApp)));
      await act(async () => host.cmuxAcpmuxBridge!.receive({ type: "snapshot", protocolVersion: 1, rows: turn, sessions: [], connection: "connected", isWorking: false, queue: [], catalog: [], canLoadOlder: false }));
      const review = [...document.querySelectorAll("button")].find((button) => button.textContent === "Review changes");
      expect(review).toBeDefined();
      (review as HTMLElement).focus();
      await act(async () => review!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      const panel = document.querySelector("section.acpmux-diff-panel")!;
      expect(panel.querySelector(".acpmux-diff-header strong")?.textContent).toBe("2 files changed");
      expect(document.activeElement?.getAttribute("aria-label")).toBe("Back to transcript");
      // Each edit is one Pierre diff with the pane's own file header, in turn order.
      expect([...panel.querySelectorAll(".acpmux-diff-file")].map((node) => (node as HTMLElement).dataset.path)).toEqual(["/repo/src/main.ts", "/repo/notes.md"]);
      expect([...panel.querySelectorAll(".acpmux-diff-file")].map((node) => node.querySelector("diffs-container") !== null)).toEqual([true, true]);
      expect(panel.querySelector(".acpmux-diff-tree file-tree-container, .acpmux-diff-tree [class*=tree]")).not.toBeNull();
      const split = [...panel.querySelectorAll(".acpmux-diff-layout button")].find((button) => button.textContent === "Split")!;
      await act(async () => split.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      expect(split.getAttribute("aria-pressed")).toBe("true");
      const back = panel.querySelector('[aria-label="Back to transcript"]')!;
      await act(async () => back.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      expect(document.querySelector(".acpmux-diff-panel")).toBeNull();
      // Focus goes back to the control that opened the view, once the transcript shows again.
      expect(document.activeElement).toBe(review!);
    } finally {
      await act(async () => root.unmount());
      delete (host as unknown as Record<string, unknown>).cmuxAcpmuxRegistry;
    }
  });

  test("a file in the edited-files row opens the changes at that file", async () => {
    const opened: [string, string | undefined][] = [];
    const root = createRoot(dom.window.document.getElementById("root")!);
    const row: AcpmuxRow = { id: "activity-1", version: 1, at: 1, kind: "activity", items: [{ kind: "tool", text: "Edit", tool: { id: "t1", title: "Edit", kind: "edit", status: "completed", diffs: [{ path: "/repo/a.ts", oldText: "1", newText: "2" }] } }] };
    try {
      await act(async () => root.render(createElement(VirtualTranscript, { rows: [row], onToggleActivity: () => {}, onOpenDiff: (rowId: string, path?: string) => opened.push([rowId, path]), expanded: new Set<string>() })));
      const file = dom.window.document.querySelector(".acpmux-edited-file")!;
      expect(file.textContent).toBe("a.ts");
      await act(async () => file.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
      expect(opened).toEqual([["activity-1", "/repo/a.ts"]]);
    } finally {
      await act(async () => root.unmount());
    }
  });
});

describe("acpmux hunk review", () => {
  test("rejected hunks go to the agent as one revert prompt, and are marked requested", async () => {
    const { DiffPanel } = await import("./DiffPanel");
    const { turnFiles } = await import("./diff");
    const files = turnFiles([{ id: "activity-1", version: 1, at: 1, kind: "activity", items: [{ kind: "tool", text: "Edit", tool: { id: "t1", title: "Edit", kind: "edit", status: "completed", diffs: [{ path: "/repo/a.ts", oldText: "one\ntwo\n", newText: "one\n2\n", line: 4 }] } }] }]);
    const root = createRoot(dom.window.document.getElementById("root")!);
    const decisions = new Map<string, "accepted" | "rejected" | "requested">();
    const sent: { keys: string[]; prompt: string }[] = [];
    const render = () => root.render(createElement(DiffPanel, { files, onClose: () => {}, review: { decisions: new Map(decisions), decide: (key: string, decision?: "accepted" | "rejected" | "requested") => { if (decision) decisions.set(key, decision); else decisions.delete(key); void act(async () => render()); }, requestRevert: (keys: string[], prompt: string) => { sent.push({ keys, prompt }); for (const key of keys) decisions.set(key, "requested"); void act(async () => render()); } } }));
    const document = dom.window.document;
    const click = (node: Element) => act(async () => { node.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })); });
    try {
      await act(async () => render());
      for (let tries = 0; tries < 50 && !document.querySelector(".acpmux-hunk-reject"); tries += 1) await act(() => new Promise((resolve) => setTimeout(resolve, 10)));
      expect(document.querySelector(".acpmux-hunk-reject")?.getAttribute("aria-label")).toBe("Reject change at a.ts line 5");
      await click(document.querySelector(".acpmux-hunk-reject")!);
      expect(document.querySelector(".acpmux-hunk-actions")?.textContent).toBe("RejectedUndo");
      // The pressed button is gone; focus moves to the Undo that replaced it.
      expect(document.activeElement?.textContent).toBe("Undo");
      expect(document.querySelector(".acpmux-revert-count")?.textContent).toBe("1 change rejected");
      await click([...document.querySelectorAll(".acpmux-revert-send")][0]);
      expect(sent.length).toBe(1);
      expect(sent[0].prompt).toContain("--- /repo/a.ts\n+++ /repo/a.ts\n@@ -4,2 +4,2 @@\n one\n-two\n+2");
      expect(document.querySelector(".acpmux-hunk-actions")?.textContent).toBe("Revert requested");
      expect(document.querySelector(".acpmux-revert-bar")).toBeNull();
      expect(document.activeElement?.getAttribute("aria-label")).toBe("Back to transcript");
    } finally {
      await act(async () => root.unmount());
    }
  });
});
