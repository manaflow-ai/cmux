// The prompt rail's hover reads (Leo, 2026-11-04: "hovering across the session rail gets a bit laggy
// ... it needs to get faster" and "hover previews kinda lag across me hovering over the sidebar stuff
// :("). A sweep crosses a row about every 40 ms, and each row the pointer reaches commits the card's
// new content. Every layout read that follows a DOM write makes the browser lay the page out again
// before the frame (a forced layout), and the card's fit read and wrote by turns: three to five
// layouts per row, on top of the frame's own.
//
// jsdom has no layout, so this counts what the browser would do: a write (a style, an attribute, a
// node) dirties the page, and the first layout read after it (a rect, an offset size, a computed
// style, a scroll offset) is one forced layout. Reads with no write between them share it.
import { afterAll, afterEach, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
// These tests drive the compact (Codex) rail; the default arm draws no minimap (layout.experiment.ts).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = {
  "thread-minimap-layout": "compact",
};

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
const observed: Element[] = [];
const queued = new Map<number, FrameRequestCallback>();
let lastFrame = 0;
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
  // Each observed element is recorded, so a test can bound the observers a hover sweep puts on the card.
  ResizeObserver: class {
    observe(target: Element) {
      observed.push(target);
    }
    unobserve() {}
    disconnect() {}
  },
  WheelEvent: dom.window.WheelEvent,
  KeyboardEvent: dom.window.KeyboardEvent,
  // Frames run when the test says (`frame`), between rows, as the browser draws between them: a frame
  // that landed inside a row's turn counted its own layouts there.
  requestAnimationFrame: (callback: FrameRequestCallback) => {
    queued.set(++lastFrame, callback);
    return lastFrame;
  },
  cancelAnimationFrame: (handle: number) => void queued.delete(handle),
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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", {
  configurable: true,
  get: () => VIEWPORT,
});
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", {
  configurable: true,
  get: () => paneWidth,
});
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
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({
  id,
  kind,
  text,
  version: 1,
  at: 1,
});
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
        sessionId="rail-test"
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
const card = () => document.querySelector<HTMLElement>(".acpmux-minimap__card");
const pointer = (type: string, target: Element, init: Record<string, unknown> = {}) =>
  act(async () => {
    const Event = (dom.window as unknown as { PointerEvent?: typeof MouseEvent }).PointerEvent ?? dom.window.MouseEvent;
    target.dispatchEvent(new Event(type, { bubbles: true, cancelable: true, button: 0, ...init }));
  });
const enter = (index: number) => pointer("pointerover", tick(index), { relatedTarget: document.body });

// The dirty-page model: every write marks the page dirty; a layout read while it is dirty counts as
// one forced layout and cleans it.
let dirty = false;
let layouts = 0;
let counting = false;
const write = (_target?: unknown) => void (dirty = true);
/// The rail's and its card's own reads: the rail, the card and the layer it draws in. The
/// transcript's reads (its scroll pacer's frame, which lands in whichever row's turn it lands) are not
/// this test's.
const ours = (target: unknown) => {
  if (!(target instanceof dom.window.Element)) return false;
  const shown = document.querySelector(".acpmux-minimap__card");
  return !!target.closest(".acpmux-minimap, .acpmux-minimap__card") || target === shown?.parentElement;
};
const read = (target?: unknown) => {
  if (!counting || !dirty || !ours(target)) return;
  dirty = false;
  layouts += 1;
};
const wrapSetter = (proto: object, name: string) => {
  const desc = Object.getOwnPropertyDescriptor(proto, name);
  if (!desc?.set) return;
  const { set } = desc;
  Object.defineProperty(proto, name, {
    ...desc,
    set(this: unknown, value: unknown) {
      write();
      set.call(this, value);
    },
  });
};
const wrapGetter = (proto: object, name: string) => {
  const desc = Object.getOwnPropertyDescriptor(proto, name);
  if (!desc?.get) return;
  const { get } = desc;
  Object.defineProperty(proto, name, {
    ...desc,
    get(this: unknown) {
      read(this);
      return get.call(this);
    },
  });
};
const wrapMethod = (proto: Record<string, unknown>, name: string, then: (target: unknown) => void) => {
  const original = proto[name] as (...args: unknown[]) => unknown;
  proto[name] = function (this: unknown, ...args: unknown[]) {
    then(this);
    return original.apply(this, args);
  };
};
{
  const win = dom.window as unknown as Record<string, { prototype: Record<string, unknown> }>;
  const styleProto = Object.getPrototypeOf(document.createElement("div").style) as Record<string, unknown>;
  for (const name of Object.getOwnPropertyNames(styleProto)) wrapSetter(styleProto, name);
  const declaration = Object.getPrototypeOf(styleProto) as Record<string, unknown>;
  wrapSetter(declaration, "cssText");
  for (const name of ["setProperty", "removeProperty"]) wrapMethod(declaration, name, write);
  const element = win.Element!.prototype;
  for (const name of ["setAttribute", "removeAttribute", "toggleAttribute"]) wrapMethod(element, name, write);
  const node = win.Node!.prototype;
  for (const name of ["appendChild", "insertBefore", "removeChild", "replaceChild"]) wrapMethod(node, name, write);
  wrapSetter(node, "textContent");
  wrapSetter(node, "nodeValue");
  wrapSetter(win.CharacterData!.prototype, "data");
  wrapMethod(element, "getBoundingClientRect", read);
  const html = win.HTMLElement!.prototype;
  for (const name of [
    "offsetHeight",
    "offsetWidth",
    "offsetTop",
    "offsetLeft",
    "offsetParent",
    "scrollTop",
    "clientHeight",
    "clientWidth",
  ])
    wrapGetter(html, name);
  const computed = dom.window.getComputedStyle.bind(dom.window);
  dom.window.getComputedStyle = ((target: Element, pseudo?: string | null) => {
    read(target);
    return computed(target, pseudo);
  }) as typeof dom.window.getComputedStyle;
  scope.getComputedStyle = dom.window.getComputedStyle;
}

/// The frame after a row: what it asked for runs, and its paint leaves the page laid out.
const frame = () =>
  act(async () => {
    for (let round = 0; round < 4 && queued.size > 0; round += 1) {
      const due = [...queued.values()];
      queued.clear();
      for (const callback of due) callback(performance.now());
    }
  });

/// The forced layouts of `run`, from a clean page (the frame before it painted).
async function forcedLayouts(run: () => Promise<unknown>): Promise<number> {
  dirty = false;
  layouts = 0;
  counting = true;
  try {
    await run();
  } finally {
    counting = false;
  }
  return layouts;
}
test("a row the sweep reaches forces at most three layouts, and a row it comes back to forces one", async () => {
  const view = await mount(40);
  // No timer lands in a row's turn: a row is its commit alone.
  jest.useFakeTimers();
  try {
    // The first rows open the card and settle the transcript under the rail (its own reads, once).
    await enter(4);
    await frame();
    await enter(5);
    await frame();
    expect(card()).not.toBeNull();
    const out: number[] = [];
    for (let index = 6; index < 15; index += 1) {
      out.push(await forcedLayouts(() => enter(index)));
      await frame();
    }
    const back: number[] = [];
    for (let index = 13; index >= 6; index -= 1) {
      back.push(await forcedLayouts(() => enter(index)));
      await frame();
      expect(card()!.textContent).toContain(`Question ${index}`);
    }
    // The transcript's scroll pacer runs on the page's own clock, and its frame sometimes lands in a
    // row's turn: that commit renders the rail and its card again with the same props, and the card's
    // place() reads once more. So each row may take one read past its own, and most rows take none.
    const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
    // A row seen first: the card's reads come first and its writes after, in at most three passes
    // (the prompt's lines with the card's place, the reply's natural height, the card's own height).
    expect(median(out)).toBeLessThanOrEqual(3);
    expect(Math.max(...out)).toBeLessThanOrEqual(4);
    // A row seen before: its fit is remembered, so the card writes it and reads its place once
    // (base: four on every row).
    expect(median(back)).toBeLessThanOrEqual(1);
    expect(Math.max(...back)).toBeLessThanOrEqual(2);
  } finally {
    await view.unmount();
  }
});

test("a row the card fitted before measures again once the text size changed, at the same width", async () => {
  const view = await mount(40);
  jest.useFakeTimers();
  const sized = document.createElement("style");
  try {
    for (const index of [4, 5, 6, 7]) {
      await enter(index);
      await frame();
    }
    const reply = () => card()!.querySelector<HTMLElement>(".acpmux-minimap__reply")!;
    const before = reply().style.getPropertyValue("--acpmux-minimap-reply-line-height");
    // A larger text size (or a denser layout) while the card is elsewhere: its observer sees no
    // resize for this row, and the card is as wide as it was.
    sized.textContent = ".acpmux-minimap__reply { line-height: 31px; } .acpmux-minimap__prompt { line-height: 27px; }";
    document.head.append(sized);
    await enter(5);
    await frame();
    expect(card()!.textContent).toContain("Question 5");
    expect(before).not.toBe("31px");
    expect(reply().style.getPropertyValue("--acpmux-minimap-reply-line-height")).toBe("31px");
  } finally {
    sized.remove();
    await view.unmount();
  }
});
