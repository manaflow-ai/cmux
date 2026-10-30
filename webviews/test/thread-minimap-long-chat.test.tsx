// The compact rail on a long chat draws only the rows in its view (tickWindow.ts): a 2,000-turn chat
// mounts a bounded number of ticks, and the keyboard still reaches every prompt, Tab, arrows and
// Home/End alike. Its 1,000 buttons cost 34 ms a frame at p95 while scrolling a 2,000-row chat and
// 42 ms while a reply streamed (bench/thread-minimap-frame-cost.bench.ts).
import { afterAll, expect, test } from "bun:test";
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
const resizeObservers = new Set<{ fire(): void }>();
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
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  // Kept, so a test that changes the transcript's height can tell the pane it resized.
  ResizeObserver: class {
    constructor(private readonly callback: () => void) {
      resizeObservers.add(this);
    }
    observe() {}
    unobserve() {}
    disconnect() {
      resizeObservers.delete(this);
    }
    fire() {
      this.callback();
    }
  },
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
let viewport = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => viewport });
// Wide enough for the minimap's usable gutter (ThreadMinimap RAIL_MIN_GUTTER).
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
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
// A browser scrolls the rail's list to a row that takes focus; the list's scroll event then moves the
// drawn rows along. jsdom scrolls nothing, so focus does it here.
dom.window.document.addEventListener(
  "focusin",
  (event) => {
    const tick = (event.target as HTMLElement).closest?.<HTMLElement>("[data-tick]");
    const list = tick?.closest<HTMLElement>(".acpmux-minimap__list");
    if (!tick || !list) return;
    const top = Number(tick.dataset.tick) * 10;
    const room = Number.parseFloat(list.parentElement!.style.height);
    const at = list.scrollTop;
    if (top >= at && top + 10 <= at + room) return;
    list.scrollTop = top < at ? top : top + 10 - room;
    list.dispatchEvent(new dom.window.Event("scroll"));
  },
  true,
);
const jumps: number[] = [];
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  const top = typeof options === "number" ? 0 : (options?.top ?? 0);
  jumps.push(top);
  this.scrollTop = top;
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const TURNS = 2000;
const turns = Array.from({ length: TURNS }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();
/// Far fewer than the prompts: the rail's view (at most 60 rows in a 600 px pane) and the rows past it.
const MAX_TICKS = 120;

test("a 2,000-turn chat draws a bounded number of ticks, and the keyboard reaches every prompt", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    const ticks = () => [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")];
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const tick = (index: number) => document.querySelector<HTMLElement>(`[data-tick="${index}"]`);
    /// A key on `target`; a Tab the page leaves to the browser moves focus to the next or previous
    /// row in the DOM, as a browser's Tab does (jsdom has none).
    const key = (target: HTMLElement, name: string, shiftKey = false) =>
      act(async () => {
        const event = new dom.window.KeyboardEvent("keydown", { key: name, shiftKey, bubbles: true, cancelable: true });
        if (!target.dispatchEvent(event) || name !== "Tab") return;
        const rows = ticks();
        rows[rows.indexOf(target) + (shiftKey ? -1 : 1)]?.focus();
      });
    const focused = () => Number((document.activeElement as HTMLElement | null)?.dataset.tick ?? -1);
    // A bounded number of buttons, the latest prompt among them, and the list as tall as every row.
    expect(ticks().length).toBeGreaterThan(0);
    expect(ticks().length).toBeLessThanOrEqual(MAX_TICKS);
    expect(tick(TURNS - 1)).not.toBeNull();
    expect(tick(0)).toBeNull();
    const height = [...list.children].reduce(
      (sum, child) =>
        sum + (child.querySelector("[data-tick]") ? 10 : Number.parseFloat((child as HTMLElement).style.height) || 0),
      0,
    );
    expect(height).toBe(TURNS * 10);
    // Each row keeps its label: its place among all 2,000 and its prompt.
    expect(tick(TURNS - 1)!.getAttribute("aria-label")).toContain(`${TURNS}`);
    expect(tick(TURNS - 1)!.getAttribute("aria-label")).toContain(`Question ${TURNS - 1}`);

    // Home from the latest prompt reaches the first, which was not drawn.
    await act(async () => tick(TURNS - 1)!.focus());
    await key(tick(TURNS - 1)!, "Home");
    expect(focused()).toBe(0);
    expect(ticks().length).toBeLessThanOrEqual(MAX_TICKS);
    // Arrow Down walks every prompt to the last, one at a time, never drawing them all.
    let most = 0;
    for (let index = 1; index < TURNS; index += 1) {
      await key(document.activeElement as HTMLElement, "ArrowDown");
      if (focused() !== index) throw new Error(`ArrowDown from ${index - 1} focused ${focused()}`);
      if (index % 50 === 0) most = Math.max(most, ticks().length);
    }
    expect(most).toBeLessThanOrEqual(MAX_TICKS);
    // End and Home jump across the chat; Tab and Shift-Tab step past the drawn rows.
    await key(document.activeElement as HTMLElement, "Home");
    expect(focused()).toBe(0);
    await key(document.activeElement as HTMLElement, "End");
    expect(focused()).toBe(TURNS - 1);
    for (let index = TURNS - 2; index >= TURNS - 200; index -= 1) {
      await key(document.activeElement as HTMLElement, "Tab", true);
      if (focused() !== index) throw new Error(`Shift-Tab to ${index} focused ${focused()}`);
    }
    for (let index = TURNS - 199; index < TURNS; index += 1) {
      await key(document.activeElement as HTMLElement, "Tab");
      if (focused() !== index) throw new Error(`Tab to ${index} focused ${focused()}`);
    }
    expect(ticks().length).toBeLessThanOrEqual(MAX_TICKS);
  } finally {
    await act(async () => root.unmount());
  }
}, 300_000);

/// Turns `from` to `to - 1` of a long chat, by their own ids, so older ones can arrive above.
const span = (from: number, to: number) =>
  Array.from({ length: to - from }, (_, offset) => {
    const index = from + offset;
    return [
      row(`t${index}-user`, "user", `Question ${index}`),
      row(`t${index}-answer`, "assistant", `Answer ${index}.`),
      { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
    ];
  }).flat();

test("older turns arriving above keep focus on the focused prompt's tick", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const show = (rows: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="long-prepend"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    await show(span(300, 2000));
    const latest = document.querySelector<HTMLElement>(`[data-tick="${2000 - 300 - 1}"]`)!;
    await act(async () => latest.focus());
    await act(async () => {
      latest.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Home", bubbles: true, cancelable: true }));
    });
    const first = document.activeElement as HTMLElement;
    expect(first.getAttribute("aria-label")).toContain("Question 300");
    // 300 older turns load above: the focused prompt is now row 300, far from the rows drawn before.
    await show(span(0, 2000));
    const now = document.activeElement as HTMLElement;
    expect(now.dataset.tick).toBe("300");
    expect(now.getAttribute("aria-label")).toContain("Question 300");
    expect(now).toBe(first);
  } finally {
    await act(async () => root.unmount());
  }
}, 120_000);

test("a rail scrolled to the end of a long chat shows every tick of a short one it switches to", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const show = (rows: AcpmuxRow[], sessionId: string) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId={sessionId}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    await show(span(0, 2000), "long-switch-a");
    // It opens at the latest message, the list scrolled to its end.
    expect(document.querySelector(`[data-tick="1999"]`)).not.toBeNull();
    expect(document.querySelector<HTMLElement>(".acpmux-minimap__list")!.scrollTop).toBeGreaterThan(1000);
    await show(span(0, 5), "long-switch-b");
    const ticks = [...document.querySelectorAll<HTMLElement>("[data-tick]")].map((node) => node.dataset.tick);
    expect(ticks).toEqual(["0", "1", "2", "3", "4"]);
  } finally {
    await act(async () => root.unmount());
  }
}, 120_000);

test("each drawn tick is a list item that names its place among every prompt", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    /// An element's role, its own or its tag's.
    const roleOf = (node: Element) =>
      node.getAttribute("role") ?? ({ OL: "list", UL: "list", LI: "listitem" } as Record<string, string>)[node.tagName];
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    expect(roleOf(list)).toBe("list");
    const ticks = [...list.querySelectorAll<HTMLElement>("[data-tick]")];
    expect(ticks.length).toBeGreaterThan(0);
    for (const tick of ticks) {
      const item = tick.parentElement!;
      expect(roleOf(item)).toBe("listitem");
      expect(item.parentElement).toBe(list);
      expect(item.getAttribute("aria-posinset")).toBe(String(Number(tick.dataset.tick) + 1));
      expect(item.getAttribute("aria-setsize")).toBe(String(TURNS));
    }
    // The spacers for the rows not drawn are out of the accessibility tree.
    for (const child of list.children)
      if (!child.querySelector("[data-tick]")) expect(child.getAttribute("aria-hidden")).toBe("true");
  } finally {
    await act(async () => root.unmount());
  }
}, 120_000);

test("a clicked tick keeps focus while the chat scrolls it out of the rail's window", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(span(0, 2000), new Set())}
          sessionId="long-click"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    // A pointer click on the latest prompt's tick: it takes focus as a clicked button does, which
    // neither grows it nor opens the card (no keyboard focus, no hover, no card hold it drawn).
    const clicked = document.querySelector<HTMLElement>(`[data-tick="1999"]`)!;
    await act(async () => clicked.click());
    expect(document.activeElement).toBe(clicked);
    // The reader scrolls the chat to its top: the rail's list follows the band there, far past
    // the tick. A wheel up first, as a reader's scroll comes: a scroll with no reader input is
    // layout, which never lets go of the latest row (#26088), so the view went back to its end in
    // the next frame and the read passed only when it came before that frame. The read now waits
    // for the frame the transcript commits the scroll in (its scroll pacer).
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    await act(async () => {
      scroller.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -1000, bubbles: true }));
      scroller.scrollTop = 0;
      scroller.dispatchEvent(new dom.window.Event("scroll"));
      await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(null)));
    });
    expect(scroller.scrollTop).toBe(0);
    expect(document.querySelector(`[data-tick="0"]`)).not.toBeNull();
    // The focused tick is still drawn and focused, and the keyboard goes on from it.
    expect(clicked.isConnected).toBe(true);
    expect(document.activeElement).toBe(clicked);
    await act(async () => {
      clicked.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true, cancelable: true }),
      );
    });
    expect((document.activeElement as HTMLElement).dataset.tick).toBe("1998");
  } finally {
    await act(async () => root.unmount());
  }
}, 120_000);

test("after earlier turns go, streaming does no search of the ticks, and the card stays on its prompt", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  // Every element a findIndex visits on a tick list (items with a key and a prompt), as it runs.
  const findIndex = Array.prototype.findIndex;
  let visited = 0;
  Array.prototype.findIndex = function (this: unknown[], ...args: Parameters<typeof findIndex>) {
    const first = this[0] as { key?: unknown; prompt?: unknown } | undefined;
    if (first && typeof first === "object" && "key" in first && "prompt" in first) visited += this.length;
    return findIndex.apply(this, args);
  } as typeof findIndex;
  const show = (rows: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="long-shrink"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    const chat = span(0, 2000);
    await show(chat);
    // Keyboard focus on the latest prompt's tick: it grows and its card opens.
    const latest = document.querySelector<HTMLElement>(`[data-tick="1999"]`)!;
    await act(async () => latest.focus());
    expect(document.querySelector(".acpmux-minimap__card")?.textContent).toContain("Question 1999");
    // The first 500 turns go (the chat is cut): the prompt is now row 1499.
    const kept = chat.slice(500 * 3);
    await show(kept);
    expect((document.activeElement as HTMLElement).dataset.tick).toBe("1499");
    // 200 tokens stream into the last reply: no render searches the ticks for the focused prompt.
    const at = kept.findIndex((item) => item.id === "t1999-answer");
    visited = 0;
    let reply = "Answer 1999.";
    for (let token = 0; token < 200; token += 1) {
      reply += ` word${token}`;
      const rows = kept.slice();
      rows[at] = { ...kept[at]!, text: reply, version: token + 2 };
      await show(rows);
    }
    expect(visited).toBe(0);
    // The card and the grown, active tick are the focused prompt's.
    const active = document.querySelector<HTMLElement>('[data-tick][data-tone="active"]');
    expect(active?.dataset.tick).toBe("1499");
    expect(active?.getAttribute("aria-label")).toContain("Question 1999");
    expect(document.querySelector(".acpmux-minimap__card")?.textContent).toContain("Question 1999");
  } finally {
    Array.prototype.findIndex = findIndex;
    await act(async () => root.unmount());
  }
}, 300_000);

test("a focused tick that goes away with its chat is not held drawn when the chat comes back", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const show = (rows: AcpmuxRow[], sessionId: string) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId={sessionId}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    const long = span(0, 2000);
    await show(long, "long-away-a");
    const rail = document.querySelector(".acpmux-minimap__rail");
    const clicked = document.querySelector<HTMLElement>(`[data-tick="1999"]`)!;
    await act(async () => clicked.click());
    expect(document.activeElement).toBe(clicked);
    // Another chat replaces it in the same rail: the focused button goes with no blur (jsdom, as a
    // browser may, sends none for a removed element), and the page's focus is elsewhere.
    await show(span(0, 5), "long-away-b");
    expect(document.querySelector(".acpmux-minimap__rail")).toBe(rail);
    expect(clicked.isConnected).toBe(false);
    // The first chat comes back and the reader scrolls to its top: only the rows in the rail's
    // window are drawn, not the tick that had focus before.
    await show(long, "long-away-a");
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    scroller.scrollTop = 0;
    await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
    expect(document.querySelector(`[data-tick="0"]`)).not.toBeNull();
    expect(document.querySelector(`[data-tick="1999"]`)).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
}, 120_000);

test("a focused tick whose rail hides and comes back in the same chat is not held drawn", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const show = (rows: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="long-hide"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  const scroller = () => document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const scrollTo = async (top: number) => {
    scroller().scrollTop = top;
    await act(async () => void scroller().dispatchEvent(new dom.window.Event("scroll")));
  };
  try {
    const long = span(0, 2000);
    await show(long);
    // At the chat's top, a click focuses the first prompt's tick.
    await scrollTo(0);
    const clicked = document.querySelector<HTMLElement>(`[data-tick="0"]`)!;
    await act(async () => clicked.click());
    expect(document.activeElement).toBe(clicked);
    // The same chat drops to 3 prompts (fewer than the rail needs, MIN_PROMPTS): the rail goes, with
    // no blur (jsdom, as a browser may, sends none for a removed element), and the first prompt stays.
    await show(span(0, 3));
    expect(document.querySelector(".acpmux-minimap__rail")).toBeNull();
    // It comes back whole, and the reader is at its end: only the rows in the rail's window are
    // drawn, not the first prompt's tick that had focus before.
    await show(long);
    await scrollTo(1e9);
    expect(document.querySelector(`[data-tick="1999"]`)).not.toBeNull();
    expect(document.querySelector(`[data-tick="0"]`)).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
}, 120_000);

test("a keyboard-focused tick whose rail hides comes back with no tick held and no card", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  const show = (rows: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="long-hide-key"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  const scroller = () => document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const scrollTo = async (top: number) => {
    scroller().scrollTop = top;
    await act(async () => void scroller().dispatchEvent(new dom.window.Event("scroll")));
  };
  try {
    const long = span(0, 2000);
    await show(long);
    // At the chat's top, keyboard focus on the first prompt's tick: it grows and its card opens.
    await scrollTo(0);
    await act(async () => document.querySelector<HTMLElement>(`[data-tick="0"]`)!.focus());
    expect(document.querySelector(".acpmux-minimap__card")?.textContent).toContain("Question 0");
    // The same chat drops to 3 prompts: the rail goes, with no blur.
    await show(span(0, 3));
    expect(document.querySelector(".acpmux-minimap__rail")).toBeNull();
    // It comes back whole with the reader at its end: no card, and the first prompt's tick is not
    // held drawn by the focus it had before.
    await show(long);
    await scrollTo(1e9);
    expect(document.querySelector(`[data-tick="1999"]`)).not.toBeNull();
    expect(document.querySelector(`[data-tick="0"]`)).toBeNull();
    expect(document.querySelector(".acpmux-minimap__card")).toBeNull();
  } finally {
    await act(async () => root.unmount());
  }
}, 120_000);

test("a scrolled rail hidden for lack of room comes back at its place, its rows drawn", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  /// The pane at `height` px: the transcript measures it as a resize tells it to.
  const resize = async (height: number) => {
    viewport = height;
    await act(async () => {
      // A copy: a measure that re-renders can add or drop observers while this runs.
      for (const observer of Array.from(resizeObservers)) observer.fire();
    });
  };
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(span(0, 2000), new Set())}
          sessionId="long-room"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    // It opens at the latest message, the rail's list scrolled to its end.
    const before = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    expect(before.scrollTop).toBeGreaterThan(1000);
    // Too short for a single row: the rail goes.
    await resize(5);
    expect(document.querySelector(".acpmux-minimap__rail")).toBeNull();
    // Back to its height: the rail comes back with a new list, scrolled to where its rows are.
    await resize(600);
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    expect(list).not.toBe(before);
    expect(list.scrollTop).toBeGreaterThan(1000);
    const height = Number.parseFloat(list.parentElement!.style.height);
    for (const row of [Math.floor(list.scrollTop / 10), Math.floor((list.scrollTop + height) / 10) - 1])
      expect(document.querySelector(`[data-tick="${row}"]`)).not.toBeNull();
    expect(document.querySelector(`[data-tick="1999"]`)).not.toBeNull();
  } finally {
    viewport = 600;
    await act(async () => root.unmount());
  }
}, 120_000);
