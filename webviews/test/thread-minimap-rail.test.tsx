// The thread minimap as the Codex desktop app's prompt rail (minimap-ref SPEC): it shows from four
// prompts at any pane width (a narrow one: thread-minimap-narrow.test.tsx); hover magnifies like
// the Dock and opens a preview card on Codex's timing; every row is a tab stop whose focus opens
// the card at once; a click or Return jumps; a drag scrubs; bookmarks show as a dot past the tick,
// toggle from the dot, the card and the prompt's own row, and the Previous and Next Bookmarked
// Prompt actions step through them. Scroll motion and the landing highlight run under Reduce
// Motion here (instant); the browser test (thread-minimap-motion.test.ts) checks their curves.
import { afterAll, afterEach, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
// These tests drive the compact (Codex) rail; the default arm draws no minimap (layout.experiment.ts).
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

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
  WheelEvent: dom.window.WheelEvent,
  KeyboardEvent: dom.window.KeyboardEvent,
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
const advance = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));
/// The place of a mounted row in the thread: its `top` less the thread's 16 px top padding.
const rowTop = (id: string) =>
  Number.parseFloat(document.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`)!.style.top) - 16;
/// Where a jump to turn `index` leaves the scroller: the prompt's bubble 35 px below the viewport
/// top (the thread pads its rows 16 px down).
const landing = (index: number) => {
  const total = parseFloat(document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
  return Math.max(0, Math.min(16 + rowTop(`user-${index + 1}`) - 35, total - VIEWPORT));
};

test("the rail shows from four prompts, at any pane width", async () => {
  for (const [prompts, width, shown] of [
    [3, 1040, false],
    [4, 1040, true],
    // An 800 px pane starts the column 40 px in: the narrow rail (thread-minimap-narrow.test.tsx).
    [6, 800, true],
    [6, 1040, true],
  ] as const) {
    paneWidth = width;
    const view = await mount(prompts);
    try {
      expect({ prompts, width, shown: document.querySelector(".acpmux-minimap__rail") !== null }).toEqual({
        prompts,
        width,
        shown,
      });
    } finally {
      await view.unmount();
    }
  }
});

test("rows are 10 px tab stops; every prompt on screen is current; hover magnifies like the Dock", async () => {
  const view = await mount(12);
  try {
    expect(ticks()).toHaveLength(12);
    // Every row is a tab stop (Tab and Shift-Tab walk them), each a button in the nav.
    expect(ticks().every((node) => node.tabIndex === 0 && node.tagName === "BUTTON")).toBe(true);
    // At rest every tick is 6 px, and the prompts on screen are all current.
    expect(ticks().map((_, index) => Math.round(length(index)))).toEqual(Array(12).fill(6));
    expect(tick(0).getAttribute("aria-current")).toBe("true");
    expect(ticks().filter((node) => node.getAttribute("aria-current") === "true").length).toBeGreaterThan(1);
    // Hovering row 5: 26 px, then 20, 14 and 10 px either side, 6 px beyond.
    await enter(5);
    expect(ticks().map((_, index) => Math.round(length(index)))).toEqual([6, 6, 10, 14, 20, 26, 20, 14, 10, 6, 6, 6]);
    expect(tick(5).dataset.tone).toBe("active");
    // Leaving the rail puts every tick back to rest.
    await leave(5);
    expect(ticks().map((_, index) => Math.round(length(index)))).toEqual(Array(12).fill(6));
  } finally {
    await view.unmount();
  }
});

test("the card waits Codex's 250 ms, follows the pointer at once while warm, and goes as the pointer leaves", async () => {
  const view = await mount(8);
  jest.useFakeTimers();
  try {
    await enter(3);
    await advance(230);
    expect(card()).toBeNull();
    await advance(30);
    expect(card()).not.toBeNull();
    expect(card()!.textContent).toContain("Question 3");
    // Moving to another row moves the card with it, on the same frame.
    await enter(4);
    expect(card()!.textContent).toContain("Question 4");
    expect(tick(4).getAttribute("aria-describedby")).toBe(card()!.id);
    // Leaving the rail (not for the card): the card goes at once.
    await leave(4);
    expect(card()).toBeNull();
    // Back while the rail is warm: at once.
    await advance(300);
    await enter(2);
    expect(card()!.textContent).toContain("Question 2");
    // Into the card: it stays.
    await pointer("pointerout", tick(2), { relatedTarget: card() });
    await advance(1_000);
    expect(card()!.textContent).toContain("Question 2");
    await pointer("pointerout", card()!, { relatedTarget: document.body });
    expect(card()).toBeNull();
    await advance(600);
    // Cooled: the 250 ms again.
    await enter(6);
    expect(card()).toBeNull();
    await advance(260);
    expect(card()).not.toBeNull();
  } finally {
    await view.unmount();
  }
});

test("keyboard focus grows its row alone and opens the card at once; Escape closes it; Return jumps", async () => {
  const view = await mount(12);
  try {
    await act(async () => tick(6).focus());
    expect(card()?.textContent).toContain("Question 6");
    expect(Math.round(length(6))).toBe(26);
    // No neighbor magnification for focus.
    expect([5, 7].map((index) => Math.round(length(index)))).toEqual([6, 6]);
    await act(async () => {
      tick(6).dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(card()).toBeNull();
    expect(document.activeElement).toBe(tick(6));
    // Return on a button is its click: the transcript lands on the prompt.
    await act(async () => tick(6).click());
    await view.scrolled();
    expect(view.scroller.scrollTop).toBe(landing(6));
  } finally {
    await view.unmount();
  }
});

test("focus in the card keeps it; Escape there or focus leaving rail and card closes it", async () => {
  const view = await mount(12);
  try {
    await act(async () => tick(6).focus());
    const bookmark = () => card()!.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!;
    await act(async () => bookmark().focus());
    expect(card()?.textContent).toContain("Question 6");
    await act(async () => {
      bookmark().dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    });
    expect(card()).toBeNull();
    await act(async () => tick(6).focus());
    await act(async () => bookmark().focus());
    expect(card()).not.toBeNull();
    // Tab on past the card: focus goes to the page.
    await act(async () => {
      bookmark().blur();
      document.body.focus();
    });
    expect(card()).toBeNull();
  } finally {
    await view.unmount();
  }
});

test("the rail never outgrows a short transcript", async () => {
  const { railHeight } = await import("../src/agent-session/acpmux/threadMinimap/model");
  // 60 prompts in an 820 px window over a 400 px transcript: the rail fits the transcript, less the
  // mask's bands (18 and 56 px) and 4 px past each.
  expect(railHeight(60, 820, 400)).toBe(400 - 22 - 60);
  expect(railHeight(60, 820, 820)).toBe(Math.min(600, Math.floor(820 * 0.7)));
  // Not measured yet: the window caps it alone.
  expect(railHeight(60, 820, 0)).toBe(railHeight(60, 820));
});

test("a clicked row takes focus, as a clicked button does in Codex, so Tab goes on from the rail; the click does not hold the card open", async () => {
  const view = await mount(12);
  jest.useFakeTimers();
  try {
    await enter(4);
    await advance(500);
    expect(card()?.textContent).toContain("Question 4");
    // WebKit does not focus a clicked button; the rail does, so Tab moves to the next row.
    await act(async () => tick(4).click());
    expect(document.activeElement).toBe(tick(4));
    await leave(4);
    await advance(200);
    expect(card()).toBeNull();
    expect(Math.round(length(4))).toBe(6);
  } finally {
    await view.unmount();
  }
});

test("dragging on the rail scrubs: each row crossed jumps the transcript to it, and the drag's click does not", async () => {
  const view = await mount(12);
  try {
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    // jsdom lays nothing out: the list's top is 0, so row n spans n*10 to n*10+10.
    await pointer("pointerdown", tick(1), { clientY: 15 });
    await pointer("pointermove", list, { clientY: 45 });
    await view.scrolled();
    expect(list.closest("nav")!.hasAttribute("data-scrubbing")).toBe(true);
    expect(view.scroller.scrollTop).toBe(landing(4));
    await pointer("pointermove", list, { clientY: 75 });
    await view.scrolled();
    expect(view.scroller.scrollTop).toBe(landing(7));
    expect(Math.round(length(7))).toBe(26);
    await pointer("pointerup", list, { clientY: 75 });
    await act(async () => tick(1).click());
    await view.scrolled();
    expect(view.scroller.scrollTop).toBe(landing(7));
    expect(list.closest("nav")!.hasAttribute("data-scrubbing")).toBe(false);
  } finally {
    await view.unmount();
  }
});

test("a press released off the rail ends there: a later hover does not scrub", async () => {
  const view = await mount(12);
  try {
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const before = view.scroller.scrollTop;
    await pointer("pointerdown", tick(1), { clientY: 15 });
    // Slid sideways off the rail and released over the transcript.
    await pointer("pointerup", document.body, { clientY: 15 });
    await pointer("pointermove", list, { clientY: 45 });
    await pointer("pointermove", list, { clientY: 75 });
    await view.scrolled();
    expect(list.closest("nav")!.hasAttribute("data-scrubbing")).toBe(false);
    expect(view.scroller.scrollTop).toBe(before);
  } finally {
    await view.unmount();
  }
});

test("a bookmark shows as the tick's dot; the dot and the card toggle it; a prompt's row has no Pin", async () => {
  const view = await mount(8);
  try {
    // Leo's prompt row (2026-10-21): check, age, Copy, Retry, Fork; no Pin under a prompt.
    expect(document.querySelector('.acpmux-row[data-row-id^="user-"] .cv-message-pin')).toBeNull();
    expect(tick(2).hasAttribute("data-bookmarked")).toBe(false);
    // The card marks it: the rail's tick gets its dot.
    await act(async () => tick(2).focus());
    const cardButton = () => card()!.querySelector<HTMLElement>(".acpmux-minimap__bookmark")!;
    await act(async () => cardButton().click());
    expect(tick(2).hasAttribute("data-bookmarked")).toBe(true);
    expect(tick(2).querySelector(".acpmux-minimap__dot")).not.toBeNull();
    // The card shows it filled, and its button removes it.
    expect(cardButton().getAttribute("aria-pressed")).toBe("true");
    await act(async () => cardButton().click());
    expect(tick(2).hasAttribute("data-bookmarked")).toBe(false);
    // A click on the dot's spot past a hovered tick toggles the mark and does not jump.
    const before = view.scroller.scrollTop;
    await enter(5);
    await act(async () => tick(5).querySelector<HTMLElement>("[data-dot-hit]")!.click());
    expect(tick(5).hasAttribute("data-bookmarked")).toBe(true);
    expect(view.scroller.scrollTop).toBe(before);
    await act(async () => tick(5).querySelector<HTMLElement>("[data-dot-hit]")!.click());
    expect(tick(5).hasAttribute("data-bookmarked")).toBe(false);
  } finally {
    await view.unmount();
  }
});

test("Next and Previous Bookmarked Prompt scroll to the bookmarked prompts after and before the one being read", async () => {
  const view = await mount(12);
  const nextFrame = () => new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
  // Marked from the card: the later prompts' rows are not mounted at the top of the chat.
  const mark = async (index: number) => {
    await act(async () => tick(index).focus());
    await act(async () => card()!.querySelector<HTMLElement>(".acpmux-minimap__bookmark")!.click());
  };
  const step = async (name: "nextBookmarkedPrompt" | "previousBookmarkedPrompt") => {
    await act(async () => void dom.window.dispatchEvent(new dom.window.CustomEvent(`cmux-acpmux-${name}`)));
    await view.scrolled();
    // The jump's direct scroll and the transcript's paced state commit land on consecutive frames;
    // wait through both before reading the virtualized target row.
    await act(async () => {
      await nextFrame();
      await nextFrame();
    });
  };
  try {
    await mark(2);
    await mark(8);
    await step("nextBookmarkedPrompt");
    expect(view.scroller.scrollTop).toBe(landing(2));
    await step("nextBookmarkedPrompt");
    expect(view.scroller.scrollTop).toBe(landing(8));
    // Past the last mark, Next stays.
    await step("nextBookmarkedPrompt");
    expect(view.scroller.scrollTop).toBe(landing(8));
    await step("previousBookmarkedPrompt");
    expect(view.scroller.scrollTop).toBe(landing(2));
    await mark(2);
    await mark(8);
  } finally {
    await view.unmount();
  }
});

test("the card draws outside the transcript scroller, whose edge mask would keep its blur from the rows", async () => {
  const view = await mount(8);
  try {
    await act(async () => tick(3).focus());
    expect(card()?.textContent).toContain("Question 3");
    // The scroller masks its soft edges (conversation.css), and a masked ancestor is the card's
    // backdrop root: inside it the glass showed the rows sharp through its tint (#23782).
    expect(card()!.closest(".acpmux-scroll")).toBeNull();
    expect(card()!.parentElement).toBe(view.scroller.parentElement);
    // The rail keeps an anchor where the card's x and y count from.
    expect(view.scroller.querySelector(".acpmux-minimap > .acpmux-minimap__anchor")).not.toBeNull();
  } finally {
    await view.unmount();
  }
});

test("the wheel and the scrolling keys over the card reach the transcript's own listeners, as inside it", async () => {
  const { followTrace } = await import("../src/agent-session/acpmux/followTrace");
  const { animateScroll } = await import("../src/agent-session/acpmux/threadMinimap/scrollMotion");
  const view = await mount(8);
  const input = jest.spyOn(followTrace, "input");
  try {
    await act(async () => tick(3).focus());
    expect(card()?.textContent).toContain("Question 3");
    // jsdom has no scrollBy: a card that only called it (and skipped the listeners) would scroll here.
    view.scroller.scrollBy = ((options: ScrollToOptions) => {
      view.scroller.scrollTop += options.top ?? 0;
    }) as typeof view.scroller.scrollBy;
    const heard: string[] = [];
    view.scroller.addEventListener("wheel", (event) => heard.push(`wheel ${(event as WheelEvent).deltaY}`));
    view.scroller.addEventListener("keydown", (event) => heard.push(`key ${(event as KeyboardEvent).key}`));
    // A minimap jump in flight: the reader's own wheel over the card ends it where it is.
    view.scroller.scrollTop = 1000;
    animateScroll(view.scroller, () => 5000, 60_000, [0, 0, 1, 1]);
    input.mockClear();
    await act(async () => {
      card()!.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -3, bubbles: true, cancelable: true }));
    });
    // The transcript's own wheel listeners ran: the scroll is the reader's (App.tsx), so a slow
    // scroll up from the latest row is not taken for a stray and snapped back.
    expect(heard).toEqual(["wheel -3"]);
    expect(input).toHaveBeenCalledTimes(1);
    // The jump ended where it was: the frames that follow move the transcript no further.
    const after = view.scroller.scrollTop;
    for (let frame = 0; frame < 4; frame += 1) await new Promise((resolve) => requestAnimationFrame(resolve));
    expect(view.scroller.scrollTop).toBe(after);
    // A page (deltaMode 2) is the scroller's height.
    view.scroller.scrollTop = 1000;
    await act(async () => {
      card()!.dispatchEvent(
        new dom.window.WheelEvent("wheel", { deltaY: 1, deltaMode: 2, bubbles: true, cancelable: true }),
      );
    });
    expect(view.scroller.scrollTop).toBe(1000 + VIEWPORT);
    // A pinch (ctrl) is not a scroll.
    await act(async () => {
      card()!.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: 40, ctrlKey: true, bubbles: true }));
    });
    expect(view.scroller.scrollTop).toBe(1000 + VIEWPORT);
    // Page Down with focus on the card's bookmark pages the transcript, as it did inside it.
    heard.length = 0;
    input.mockClear();
    const bookmark = card()!.querySelector<HTMLButtonElement>(".acpmux-minimap__bookmark")!;
    await act(async () => {
      bookmark.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "PageDown", bubbles: true, cancelable: true }),
      );
    });
    expect(heard).toEqual(["key PageDown"]);
    expect(input).toHaveBeenCalledTimes(1);
    expect(view.scroller.scrollTop).toBe(1000 + VIEWPORT + VIEWPORT * 0.875);
    // Return on the bookmark is its own: it scrolls nothing.
    await act(async () => {
      bookmark.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }),
      );
    });
    expect(heard).toEqual(["key PageDown"]);
  } finally {
    input.mockRestore();
    await view.unmount();
  }
});
