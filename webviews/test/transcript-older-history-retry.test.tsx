// l10n-allow-file: test fixture prompts, not shipped UI.
// Leo 2026-10-21, after restarting the app on a chat of about 720 turns: "NOW I CAN'T SEE THE PAST
// HISTORY OF THIS CHAT. WHERE IS OUR PAGINATION?" acpmux held the whole log, but one older page
// that failed, or an ask that came back with nothing (a read inside the client's back-off), left
// the transcript's ask key set with the view at the very top, where a wheel up fires no scroll
// event: nothing ever asked again. An ask that brings nothing is asked again soon, and a wheel up
// at the top asks too.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
// Each element's ResizeObserver callback, which the test fires as a redrawn row would.
const observers = new Map<Element, (entries: { target: Element }[]) => void>();
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
  ResizeObserver: class {
    constructor(private readonly callback: (entries: { target: Element }[]) => void) {}
    observe(target: Element) {
      observers.set(target, this.callback);
    }
    unobserve(target: Element) {
      observers.delete(target);
    }
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

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
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
// jsdom has no layout: each row draws at a height of its own, which a redraw can change.
const drawnHeights = new Map<string, number>();
const drawnHeight = (id: string) => drawnHeights.get(id) ?? 40 + (id.length % 7) * 9;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  const height = this.dataset.rowId ? drawnHeight(this.dataset.rowId) : 0;
  return { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: height, width: 0, height, toJSON() {} } as DOMRect;
};

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

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const turn = (index: number) => [
  row(`t${index}-user`, "user", { text: `Question ${index}` }),
  row(`t${index}-answer`, "assistant", { text: `Answer ${index}.` }),
  row(`t${index}-end`, "turnSummary", { status: "completed", durationMs: 1_000 }),
];

const history = Array.from({ length: 12 }, (_, index) => turn(index + 100)).flat();
/// The transcript as the pane draws it while a reply streams: the newest answer grows every frame.
const streamed = (frame: number) => [
  ...history,
  row("live-user", "user", { text: "Question live" }),
  row("live-answer", "assistant", { text: `Streaming ${"word ".repeat(frame)}`, streaming: true }),
];

/// A transcript at the very top of its loaded history; `onLoadOlder` is called fresh each draw, as
/// the pane passes a new closure on every render (a test that hands the same function each draw
/// leaves no effect to re-run when the ask settles).
async function atTop(onLoadOlder: () => () => Promise<void>, chat = { id: "s-retry" }) {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const draw = (frame: number) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(streamed(frame), new Set(), { working: true, now: at })}
          onToggleActivity={() => {}}
          expanded={new Set()}
          canLoadOlder
          historyFrom={1_000}
          onLoadOlder={onLoadOlder()}
          sessionId={chat.id}
        />,
      ),
    );
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  await draw(0);
  // The reader scrolls to the top: one scroll event, then the view sits at 0.
  await act(async () => {
    scroller().scrollTop = 0;
    scroller().dispatchEvent(new dom.window.Event("scroll"));
  });
  return { root, draw, scroller };
}

/// Re-renders every 16ms frame for `ms` on the fake clock, with no scroll event.
async function stream(draw: (frame: number) => Promise<void>, ms: number) {
  for (let frame = 1; frame * 16 <= ms; frame += 1) {
    await draw(frame);
    await act(async () => void jest.advanceTimersByTime(16));
  }
}

test("an older page that failed is asked for again at the top, with no scroll", async () => {
  jest.useFakeTimers();
  let asked = 0;
  const ask = () => {
    asked += 1;
    return asked === 1 ? Promise.reject(new Error("socket closed")) : new Promise<void>(() => {});
  };
  const { root, draw } = await atTop(() => ask);
  try {
    expect(asked).toBe(1);
    await stream(draw, 1_000);
    expect(asked).toBe(2);
  } finally {
    await act(async () => root.unmount());
    jest.useRealTimers();
  }
});

test("an ask that settles with nothing new is asked again, at most every half second", async () => {
  jest.useFakeTimers();
  let asked = 0;
  // The client's answer inside its back-off, or to a read the selection dropped: nothing changes.
  const { root, draw } = await atTop(() => () => {
    asked += 1;
    return Promise.resolve();
  });
  try {
    expect(asked).toBe(1);
    await stream(draw, 1_100);
    expect(asked).toBeGreaterThanOrEqual(2);
    expect(asked).toBeLessThanOrEqual(3);
  } finally {
    await act(async () => root.unmount());
    jest.useRealTimers();
  }
});

test("a wheel up at the top asks for older history; a wheel down does not", async () => {
  jest.useFakeTimers();
  let asked = 0;
  const { root, scroller } = await atTop(() => () => {
    asked += 1;
    return Promise.resolve();
  });
  const wheel = (deltaY: number) =>
    act(async () => void scroller().dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY, bubbles: true })));
  try {
    expect(asked).toBe(1);
    await wheel(120);
    expect(asked).toBe(1);
    await wheel(-120);
    expect(asked).toBe(2);
  } finally {
    await act(async () => root.unmount());
    jest.useRealTimers();
  }
});

test("a late answer for the chat before does not cancel the next chat's ask again", async () => {
  jest.useFakeTimers();
  const chat = { id: "s-before" };
  const asked: string[] = [];
  let answerBefore = () => {};
  const { root, draw, scroller } = await atTop(
    () => () => {
      asked.push(chat.id);
      // The chat before's read is still out (waiting out its back-off); the next chat's brings nothing.
      return chat.id === "s-before" ? new Promise<void>((resolve) => (answerBefore = resolve)) : Promise.resolve();
    },
    chat,
  );
  try {
    expect(asked).toEqual(["s-before"]);
    chat.id = "s-next";
    await draw(1);
    await act(async () => {
      scroller().scrollTop = 0;
      scroller().dispatchEvent(new dom.window.Event("scroll"));
    });
    expect(asked).toEqual(["s-before", "s-next"]);
    await act(async () => answerBefore());
    await stream(draw, 700);
    expect(asked).toEqual(["s-before", "s-next", "s-next"]);
  } finally {
    await act(async () => root.unmount());
    jest.useRealTimers();
  }
});
