// A Find jump is the reader's move away from the latest message. #20303 made a following transcript
// snap back to the latest row on every re-measure, and Find's scroll only stops following once the
// browser reports it, a frame later. chat-find's fold case lost its match that way on loaded runners
// (react-apps-check, 2026-10-13). jsdom reports no scroll for a scrollTop write, so the race is
// deterministic here.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { ChatFind } from "../src/agent-session/acpmux/conversation/chatFind";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

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
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

// jsdom has no layout: a 600 px viewport over a long conversation, and a scroll offset that only
// moves when written, with no scroll event.
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
const turn = (index: number) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
];
const turns = Array.from({ length: 30 }, (_, index) => turn(index)).flat();
const noop = () => {};

test("a Find jump stays on its match when the transcript measures again before the scroll event", async () => {
  const rows = turnView(turns, new Set());
  const root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const latest = () =>
    parseFloat(dom.window.document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height) - VIEWPORT;
  const target = rows.findIndex((shown) => shown.id === "t3-user");
  const find: ChatFind = {
    open: true,
    query: "Question 3",
    matches: [{ rowIndex: target, rowId: "t3-user", occurrence: 0 }],
    active: 0,
    show: noop,
    hide: noop,
    setQuery: noop,
    next: noop,
    previous: noop,
    focusRequest: 1,
  };
  const render = (shown: AcpmuxRow[], withFind?: ChatFind) =>
    root.render(<VirtualTranscript rows={shown} onToggleActivity={noop} expanded={new Set()} find={withFind} />);
  try {
    await act(async () => render(rows));
    expect(scroller().scrollTop).toBe(latest());

    // Find brings an early turn's match into view. The browser reports that scroll a frame later.
    await act(async () => render(rows, find));
    const atMatch = scroller().scrollTop;
    expect(atMatch).toBeLessThan(latest() - VIEWPORT);

    // Before that scroll event, the transcript measures again (here a new turn arrives; in the
    // browser, the fold Find opened). The view stays on the match, not back at the latest message.
    await act(async () => render(turnView([...turns, ...turn(30)], new Set()), find));
    expect(scroller().scrollTop).toBe(atMatch);
  } finally {
    await act(async () => root.unmount());
  }
});

for (const mode of ["find", "count"] as const) {
  test(`manual input cancels a pending ${mode} reveal before its row arrives`, async () => {
    const rows = turnView(turns, new Set());
    const root = createRoot(dom.window.document.getElementById("root")!);
    const late = row("late-answer", "assistant", "Late answer.\n\n".repeat(30));
    const find: ChatFind = {
      open: true,
      query: "Late answer",
      matches: [{ rowIndex: rows.length, rowId: late.id, occurrence: 0 }],
      active: 0,
      show: noop,
      hide: noop,
      setQuery: noop,
      next: noop,
      previous: noop,
      focusRequest: 1,
    };
    const render = (shown: AcpmuxRow[], key = 1) =>
      root.render(
        <VirtualTranscript
          rows={shown}
          onToggleActivity={noop}
          expanded={new Set()}
          find={mode === "find" ? { ...find, query: key === 1 ? "Late answer" : "Late" } : undefined}
          reveal={mode === "count" ? { rowId: late.id, key, toolId: "late" } : undefined}
        />,
      );
    try {
      await act(async () => render(rows));
      const node = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
      await act(async () => {
        node.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -80 }));
        node.scrollTop -= 80;
        node.dispatchEvent(new dom.window.Event("scroll", { bubbles: true }));
      });
      const parked = node.scrollTop;
      await act(async () => render([...rows, late]));
      expect(node.scrollTop).toBe(parked);
      // A new explicit request remains usable within the same input hold.
      await act(async () => render([...rows, late], 2));
      expect(node.scrollTop).toBeGreaterThan(parked);
    } finally {
      await act(async () => root.unmount());
    }
  });
}

test("held input does not apply a browser clamp twice when rows above shrink", async () => {
  const rows = turnView(turns, new Set());
  const tall = rows.map((item) =>
    item.id === "t0-answer" ? { ...item, text: "A tall paragraph.\n\n".repeat(30) } : item,
  );
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (shown: AcpmuxRow[]) =>
    root.render(<VirtualTranscript rows={shown} onToggleActivity={noop} expanded={new Set()} />);
  try {
    await act(async () => render(tall));
    const node = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const height = () => parseFloat(node.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
    const oldHeight = height();
    await act(async () => {
      node.dispatchEvent(new dom.window.WheelEvent("wheel", { deltaY: -100 }));
      node.scrollTop -= 100;
      node.dispatchEvent(new dom.window.Event("scroll", { bubbles: true }));
    });
    const parked = node.scrollTop;
    // Model the browser clamping the live offset in the DOM commit before React's layout pass.
    Object.defineProperty(node, "scrollHeight", { configurable: true, get: height });
    Object.defineProperty(node, "scrollTop", {
      configurable: true,
      get() {
        return Math.min(offsets.get(node) ?? 0, height() - VIEWPORT);
      },
      set(top: number) {
        offsets.set(node, Math.min(top, height() - VIEWPORT));
      },
    });
    await act(async () => render(rows));
    expect(oldHeight - height()).toBeGreaterThan(100);
    expect(node.scrollTop).toBeCloseTo(parked - (oldHeight - height()), 4);
  } finally {
    await act(async () => root.unmount());
  }
});

test("quiet expiry places a final streamed chunk without another token", async () => {
  jest.useFakeTimers();
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (shown: AcpmuxRow[]) =>
    root.render(<VirtualTranscript rows={shown} onToggleActivity={noop} expanded={new Set()} />);
  try {
    await act(async () => render(turnView(turns, new Set())));
    const node = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const before = node.scrollTop;
    await act(async () => {
      node.dispatchEvent(new dom.window.Event("pointerdown", { bubbles: true }));
      render(turnView([...turns, ...turn(30), ...turn(31)], new Set()));
    });
    expect(node.scrollTop).toBe(before);
    await act(async () => {
      dom.window.document.dispatchEvent(new dom.window.Event("pointerup"));
      jest.advanceTimersByTime(999);
    });
    expect(node.scrollTop).toBe(before);
    await act(async () => {
      jest.advanceTimersByTime(1);
    });
    const latest = parseFloat(node.querySelector<HTMLElement>(".acpmux-spacer")!.style.height) - VIEWPORT;
    expect(node.scrollTop).toBe(latest);
    expect(node.scrollTop).toBeGreaterThan(before);
  } finally {
    await act(async () => root.unmount());
    jest.useRealTimers();
  }
});
