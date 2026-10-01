import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "./model";

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
