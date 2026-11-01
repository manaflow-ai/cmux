// The pane-pinned rail in a narrow pane (Leo 2026-10-28: it should compress, then hide only while it
// would overlap text, with a live hover strip that reveals it). It uses a spacing-token edge inset and
// keeps the rail and card usable at every pane width.
import { afterAll, afterEach, expect, jest, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
// Reduce Motion is on unless a test turns it off: the occluded rail's leave grace is skipped under it.
let reduceMotion = true;
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
  matchMedia: (query: string) => ({ matches: reduceMotion && query.includes("reduce"), media: query }),
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
const { HOVER_INTENT } = await import("../src/ui/hoverIntent");
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
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});
afterEach(() => {
  paneWidth = 1040;
  reduceMotion = true;
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
        sessionId="rail-narrow"
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

const ticks = () => [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")];
const tick = (index: number) => ticks()[index]!;
/// A tick's drawn length in px, from its bar's scale of the 26 px box.
const length = (index: number) =>
  26 *
  Number(
    /scaleX\(([\d.]+)\)/.exec(tick(index).querySelector<HTMLElement>(".acpmux-minimap__bar")!.style.transform)?.[1],
  );
const pointer = (type: string, target: Element, init: Record<string, unknown> = {}) =>
  act(async () => {
    const Event = (dom.window as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? dom.window.MouseEvent;
    target.dispatchEvent(new Event(type, { bubbles: true, cancelable: true, button: 0, ...init }));
  });
const enter = (index: number) => pointer("pointerover", tick(index), { relatedTarget: document.body });
const leave = (index: number) => pointer("pointerout", tick(index), { relatedTarget: document.body });

/// The rail's box, from its inline style.
const railBox = () => {
  const rail = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail");
  if (!rail) return undefined;
  return { left: Number.parseFloat(rail.style.left), width: Number.parseFloat(rail.style.width), rail };
};
const lengths = () => ticks().map((_, index) => Math.round(length(index) * 10) / 10);

for (const width of [800, 780])
  test(`a ${width} px pane still draws the rail, every prompt a tick and the band lit`, async () => {
    paneWidth = width;
    const view = await mount(12);
    try {
      expect(railBox()).toBeDefined();
      expect(ticks()).toHaveLength(12);
      expect(ticks().filter((node) => node.getAttribute("aria-current") === "true").length).toBeGreaterThan(0);
    } finally {
      await view.unmount();
    }
  });

test("as the pane narrows the rail keeps its full look and stays close to the text", async () => {
  paneWidth = 800;
  const view = await mount(12);
  try {
    const box = railBox()!;
    expect(box.rail.hasAttribute("data-narrow")).toBe(false);
    expect(box.rail.hasAttribute("data-expanded")).toBe(false);
    expect(box.left).toBe(8);
    expect(box.left).toBeGreaterThanOrEqual(0);
    expect(box.width).toBe(32);
    expect(lengths().every((px) => px === 6)).toBe(true);
  } finally {
    await view.unmount();
  }
});

test("hovering the close rail shows the full wave without changing its box", async () => {
  paneWidth = 800;
  const view = await mount(12);
  try {
    const rest = lengths();
    await enter(5);
    const box = railBox()!;
    expect(box.rail.hasAttribute("data-expanded")).toBe(false);
    // The full rail's 36 px rows and the Dock magnify: 26 px, then 20, 14 and 10 px, 6 px beyond.
    expect(box.width).toBe(32);
    expect(ticks().map((_, index) => Math.round(length(index)))).toEqual([6, 6, 10, 14, 20, 26, 20, 14, 10, 6, 6, 6]);
    await leave(5);
    expect(railBox()!.rail.hasAttribute("data-expanded")).toBe(false);
    expect(lengths()).toEqual(rest);
  } finally {
    await view.unmount();
  }
});

test("keyboard focus on the close rail shows the full wave too", async () => {
  paneWidth = 760;
  const view = await mount(12);
  jest.useFakeTimers();
  try {
    await act(async () => tick(3).focus());
    expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(false);
    expect(Math.round(length(3))).toBe(26);
    await act(async () => tick(3).blur());
    await advance(HOVER_INTENT.cardGrace);
    expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(true);
  } finally {
    jest.useRealTimers();
    await view.unmount();
  }
});

test("when text would overlap the rail, its edge strip reveals it and then hides it again", async () => {
  paneWidth = 760;
  // The leave grace (HOVER_INTENT.cardGrace) runs only with motion on; Reduce Motion hides at once (below).
  reduceMotion = false;
  const view = await mount(12);
  jest.useFakeTimers();
  try {
    const box = railBox()!;
    const strip = document.querySelector<HTMLElement>(".acpmux-minimap__strip")!;
    expect(box.width).toBe(20);
    expect(box.rail.hasAttribute("data-occluded")).toBe(true);
    expect(strip).toBeDefined();
    // The hidden rail would overlap the text, so its strip stops short of the rail's right edge
    // (at the text edge) and keeps at least the pane-edge inset: text clicks stay the text's.
    const stripWidth = Number.parseFloat(strip.style.width);
    expect(stripWidth).toBeLessThan(box.left + box.width);
    expect(stripWidth).toBeGreaterThanOrEqual(box.left);
    await pointer("pointerover", strip, { relatedTarget: document.body });
    expect(box.rail.hasAttribute("data-occluded")).toBe(false);
    await pointer("pointerout", strip, { relatedTarget: document.body });
    await advance(HOVER_INTENT.cardGrace - 1);
    expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(false);
    await advance(1);
    expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(true);
  } finally {
    jest.useRealTimers();
    await view.unmount();
  }
});

test("under Reduce Motion the strip's revealed rail hides as soon as the pointer leaves", async () => {
  paneWidth = 760;
  const view = await mount(12);
  jest.useFakeTimers();
  try {
    const strip = document.querySelector<HTMLElement>(".acpmux-minimap__strip")!;
    expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(true);
    await pointer("pointerover", strip, { relatedTarget: document.body });
    expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(false);
    await pointer("pointerout", strip, { relatedTarget: document.body });
    await advance(0);
    expect(railBox()!.rail.hasAttribute("data-occluded")).toBe(true);
  } finally {
    jest.useRealTimers();
    await view.unmount();
  }
});

const card = () => document.querySelector<HTMLElement>(".acpmux-minimap__card");
const advance = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));
/// Hovers row `index` until its preview card opens (at once), then moves the pointer into the
/// card, which keeps it open.
async function holdCard(index: number) {
  await enter(index);
  await advance(300);
  expect(card()?.textContent).toContain(`Question ${index}`);
  await pointer("pointerout", tick(index), { relatedTarget: card() });
  await advance(1_000);
  expect(card()?.textContent).toContain(`Question ${index}`);
}

test("with the pointer on its card, the close rail keeps the full wave around the previewed prompt", async () => {
  paneWidth = 800;
  const view = await mount(12);
  jest.useFakeTimers();
  try {
    await holdCard(5);
    const box = railBox()!;
    expect(box.rail.hasAttribute("data-expanded")).toBe(false);
    expect(box.width).toBe(32);
    expect(ticks().map((_, index) => Math.round(length(index)))).toEqual(Array(12).fill(6));
    expect(tick(5).getAttribute("data-tone")).toBe("active");
    // Off the card, and not back on the rail: the same resting rail.
    await pointer("pointerout", card()!, { relatedTarget: document.body });
    await advance(600);
    expect(railBox()!.rail.hasAttribute("data-expanded")).toBe(false);
    expect(lengths().every((px) => px === 6)).toBe(true);
  } finally {
    jest.useRealTimers();
    await view.unmount();
  }
});

// The wide rail keeps #24058's card-held look: its ticks ease back to rest as the pointer leaves the
// rail for the card, and the prompt the card previews stays lit.
test("with the pointer on its card, a wide rail keeps its ticks at rest and the previewed prompt lit", async () => {
  const view = await mount(12);
  jest.useFakeTimers();
  try {
    await holdCard(5);
    const box = railBox()!;
    expect(box.rail.hasAttribute("data-narrow")).toBe(false);
    expect({ left: box.left, width: box.width }).toEqual({ left: 10, width: 36 });
    expect(ticks().map((_, index) => Math.round(length(index)))).toEqual(Array(12).fill(6));
    expect(tick(5).getAttribute("data-tone")).toBe("active");
  } finally {
    jest.useRealTimers();
    await view.unmount();
  }
});

test("a wide pane keeps the rail close to the transcript: 36 px rows, 6 px ticks", async () => {
  const view = await mount(12);
  try {
    const box = railBox()!;
    expect(box.rail.hasAttribute("data-narrow")).toBe(false);
    expect({ left: box.left, width: box.width }).toEqual({ left: 10, width: 36 });
    expect(ticks().map((_, index) => Math.round(length(index)))).toEqual(Array(12).fill(6));
  } finally {
    await view.unmount();
  }
});

test("the rail has no narrow or tucked presentation", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
    "utf8",
  ).replace(/\/\*[\s\S]*?\*\//g, "");
  expect(css).not.toMatch(/data-narrow/);
  expect(css).not.toMatch(/NARROW_TICK|NARROW_CLEAR|tucked|divider/);
  expect(css).not.toMatch(/acpmux-minimap[^{]*\{[^}]*animation[^}]*infinite/);
});

// Leo (2026-10-24): "for the narrow windows, i think we should just simply be able to show it. don't shove
// the ui, but like... it should be fine. just hide it more". The occluded rail stays drawn, dimmed, over
// the text; it is never invisible at rest and never takes clicks from the text.
test("the occluded rail stays visible at rest, dimmed, and leaves the text its clicks", () => {
  const css = readFileSync(
    new URL("../src/agent-session/acpmux/threadMinimap/threadMinimap.css", import.meta.url),
    "utf8",
  ).replace(/\/\*[\s\S]*?\*\//g, "");
  const occluded = /\.acpmux-minimap__rail\[data-occluded\]\s*\{([^}]*)\}/.exec(css)?.[1] ?? "";
  const opacity = Number(/opacity:\s*([\d.]+)/.exec(occluded)?.[1]);
  expect(opacity).toBeGreaterThan(0);
  expect(opacity).toBeLessThan(0.75);
  expect(occluded).toMatch(/pointer-events:\s*none/);
});

test("the rail keeps a live strip at the smallest pane width", async () => {
  paneWidth = 760;
  const view = await mount(12);
  try {
    expect(document.querySelector(".acpmux-minimap__strip")).toBeDefined();
  } finally {
    await view.unmount();
  }
});
