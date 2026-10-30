// The full-height thread minimap (ScrollMap.tsx) in the transcript: every prompt and reply has a
// mark at its place, prompts are the tab stops, focus opens the preview card at once, the arrows
// walk the prompts, Return on a prompt jumps the way the compact rail does, and the marks keep
// their state while the transcript renumbers. Scroll motion runs under Reduce Motion (instant).
import { afterAll, afterEach, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
// These tests drive the full-height map; the default arm draws no minimap (layout.experiment.ts).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "full" };

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const replacements: Record<string, unknown> = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  MutationObserver: dom.window.MutationObserver,
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  // Reduce Motion: scrolls land at once, so a test reads where they land.
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport, a pane `paneWidth` wide, and a scroll offset.
const VIEWPORT = 600;
let paneWidth = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => paneWidth });
const offsets = new WeakMap<object, number>();
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: object, value: number) {
    offsets.set(this, value);
  },
});
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
// acpmux's bookmarks for the chat, answering at once (thread-bookmarks.test.tsx covers its replies).
const acpmuxMarks = new Set<number>();
setBookmarkTransport({
  get: async (sessionId) => ({ sessionId, bookmarks: [...acpmuxMarks] }),
  set: async (sessionId, seq, bookmarked) => {
    if (bookmarked) acpmuxMarks.add(seq);
    else acpmuxMarks.delete(seq);
    return { sessionId, bookmarks: [...acpmuxMarks] };
  },
});

afterAll(() => {
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});
afterEach(() => {
  jest.useRealTimers();
  paneWidth = 1040;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    // Prompt rows are `user-<seq>`, the seq acpmux logs them at (a bookmark names it).
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

async function mount(prompts: number) {
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <VirtualTranscript
        rows={turnView(chat(prompts), new Set())}
        sessionId="scroll-map-test"
        onToggleActivity={() => {}}
        expanded={new Set()}
      />,
    ),
  );
  const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const scrolled = () => act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
  await act(async () => {
    scroller.scrollTop = 0;
    scroller.dispatchEvent(new dom.window.Event("scroll"));
  });
  return { root, scroller, scrolled, unmount: () => act(async () => root.unmount()) };
}

const ticks = () => [...document.querySelectorAll<HTMLElement>('.acpmux-scrollmap__mark[data-kind="user"]')];
const tick = (index: number) => ticks()[index]!;
const card = () => document.querySelector<HTMLElement>(".acpmux-minimap__card");
/// The place of a mounted row in the thread: its `top` less the thread's 16 px top padding.
const rowTop = (id: string) =>
  Number.parseFloat(document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`)!.style.top) - 16;
/// Where a jump to turn `index` leaves the scroller: the prompt's bubble 35 px below the viewport
/// top (the thread pads its rows 16 px down).
const landing = (index: number) => {
  const total = parseFloat(document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
  return Math.max(0, Math.min(16 + rowTop(`user-${index + 1}`) - 35, total - VIEWPORT));
};

test("every prompt and every reply has a mark; prompts are tab stops, replies are not", async () => {
  const view = await mount(12);
  try {
    expect(document.querySelector(".acpmux-scrollmap")).not.toBeNull();
    expect(document.querySelector(".acpmux-scrollmap__view")).not.toBeNull();
    expect(ticks()).toHaveLength(12);
    expect(ticks().every((node) => node.tagName === "BUTTON" && node.tabIndex === 0)).toBe(true);
    const replies = [...document.querySelectorAll<HTMLElement>('.acpmux-scrollmap__mark[data-kind="agent"]')];
    expect(replies.length).toBeGreaterThan(0);
    expect(replies.every((node) => node.tagName === "SPAN")).toBe(true);
    expect(tick(3).getAttribute("aria-label")).toContain("Question 3");
  } finally {
    await view.unmount();
  }
});

test("focus opens the card at once; the arrows walk the prompts; Escape closes; Return jumps", async () => {
  const view = await mount(12);
  try {
    await act(async () => tick(6).focus());
    expect(card()?.textContent).toContain("Question 6");
    expect(tick(6).dataset.tone).toBe("active");
    expect(tick(6).getAttribute("aria-describedby")).toBe(card()!.id);
    await act(async () => {
      tick(6).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    });
    expect(document.activeElement).toBe(tick(7));
    expect(card()?.textContent).toContain("Question 7");
    await act(async () => {
      tick(7).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(card()).toBeNull();
    // Return on a button is its click: the transcript lands on the prompt.
    await act(async () => tick(7).click());
    await view.scrolled();
    expect(view.scroller.scrollTop).toBe(landing(7));
  } finally {
    await view.unmount();
  }
});

test("a focused prompt keeps its card when earlier turns arrive above it", async () => {
  const view = await mount(12);
  try {
    await act(async () => tick(4).focus());
    expect(card()?.textContent).toContain("Question 4");
    const older = [
      row("user-0", "user", "Older question"),
      row("older-answer", "assistant", "Older answer."),
      { ...row("older-end", "turnSummary"), status: "completed", durationMs: 1_000 },
    ];
    await act(async () =>
      view.root.render(
        <VirtualTranscript
          rows={turnView([...older, ...chat(12)], new Set())}
          sessionId="scroll-map-test"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    // The card follows the prompt, not the mark's old place in the list.
    expect(card()?.textContent).toContain("Question 4");
  } finally {
    await view.unmount();
  }
});

test("a chat that fits its pane above the composer has no map", async () => {
  // Two short turns: the transcript is shorter than the 600 px viewport.
  const view = await mount(2);
  try {
    expect(document.querySelector(".acpmux-scrollmap")).toBeNull();
  } finally {
    await view.unmount();
  }
});

test("the marks under the view bar are current, at the top and at the bottom", async () => {
  const view = await mount(12);
  try {
    const current = () => ticks().flatMap((node, index) => (node.dataset.tone === "current" ? [index] : []));
    expect(current()[0]).toBe(0);
    expect(current()).not.toContain(11);
    // The bottom: as far as the transcript scrolls.
    view.scroller.scrollTop =
      parseFloat(document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height) - VIEWPORT;
    await view.scrolled();
    expect(current()).toContain(11);
    expect(current()).not.toContain(0);
  } finally {
    await view.unmount();
  }
});

test("the previewed prompt stays lit while focus is on its card", async () => {
  const view = await mount(12);
  try {
    await act(async () => tick(6).focus());
    expect(tick(6).dataset.tone).toBe("active");
    const bookmark = card()!.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!;
    await act(async () => bookmark.focus());
    expect(card()?.textContent).toContain("Question 6");
    expect(tick(6).dataset.tone).toBe("active");
  } finally {
    await view.unmount();
  }
});

test("the card draws outside the transcript scroller, whose edge mask would keep its blur from the rows", async () => {
  const view = await mount(12);
  try {
    await act(async () => tick(6).focus());
    expect(card()?.textContent).toContain("Question 6");
    // A masked ancestor is the card's backdrop root (conversation.css's soft edges, #23782).
    expect(card()!.closest(".acpmux-scroll")).toBeNull();
    expect(card()!.parentElement).toBe(view.scroller.parentElement);
    expect(view.scroller.querySelector(".acpmux-minimap > .acpmux-minimap__anchor")).not.toBeNull();
  } finally {
    await view.unmount();
  }
});
