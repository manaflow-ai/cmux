// A Find jump is the reader's move away from the latest message. #20303 made a following transcript
// snap back to the latest row on every re-measure, and Find's scroll only stops following once the
// browser reports it, a frame later. chat-find's fold case lost its match that way on loaded runners
// (react-apps-check, 2026-10-13). jsdom reports no scroll for a scrollTop write, so the race is
// deterministic here.
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { ChatFind } from "../src/agent-session/acpmux/conversation/chatFind";
import type { ScrollAnchor } from "../src/agent-session/acpmux/App";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller, scrollerEnd } from "./support/jsdomScroller";

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
let viewport = VIEWPORT;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => viewport);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript, SCROLL_ANCHOR_SETTLE_MS } = await import("../src/agent-session/acpmux/App");

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
  const latest = () => scrollerEnd(dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!);
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

test("Find keeps an already visible match parked when a reply streams below it", async () => {
  const rows = turnView(turns, new Set());
  const root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const target = rows.findIndex((shown) => shown.id === "t29-user");
  const find: ChatFind = {
    open: true,
    query: "Question 29",
    matches: [{ rowIndex: target, rowId: "t29-user", occurrence: 0 }],
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
    const atMatch = scroller().scrollTop;
    await act(async () => render(rows, find));
    expect(scroller().scrollTop).toBe(atMatch);

    // A native Find command can select a match already visible at the latest message. That is
    // still the reader choosing this place: a later stream must not acquire bottom follow again.
    await act(async () => render(turnView([...turns, ...turn(30)], new Set()), find));
    expect(scroller().scrollTop).toBe(atMatch);
    await act(async () => render(turnView([...turns, ...turn(30)], new Set())));
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
    let offset = node.scrollTop;
    Object.defineProperty(node, "scrollHeight", { configurable: true, get: height });
    Object.defineProperty(node, "scrollTop", {
      configurable: true,
      get() {
        return Math.min(offset, height() - VIEWPORT);
      },
      set(top: number) {
        offset = Math.min(top, height() - VIEWPORT);
      },
    });
    await act(async () => render(rows));
    expect(oldHeight - height()).toBeGreaterThan(100);
    // Applied once: a second application would land a whole shrink (over 100 px) higher. The
    // placement pass may keep a sub-pixel residual of its rounded write (scrollCoordinates.ts).
    expect(Math.abs(node.scrollTop - (parked - (oldHeight - height())))).toBeLessThanOrEqual(1);
  } finally {
    await act(async () => root.unmount());
  }
});

test("an already visible Find match survives an immediate hide, stream and wake", async () => {
  const rows = turnView(turns, new Set());
  const more = turnView([...turns, ...turn(30)], new Set());
  let root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const target = rows.findIndex((shown) => shown.id === "t29-user");
  const find: ChatFind = {
    open: true,
    query: "Question 29",
    matches: [{ rowIndex: target, rowId: "t29-user", occurrence: 0 }],
    active: 0,
    show: noop,
    hide: noop,
    setQuery: noop,
    next: noop,
    previous: noop,
    focusRequest: 1,
  };
  const anchorNow: { current: (() => ScrollAnchor | null | undefined) | undefined } = { current: undefined };
  const reported: (ScrollAnchor | null)[] = [];
  let hideOnFind = false;
  const render = (shown: AcpmuxRow[], withFind?: ChatFind) =>
    root.render(
      <VirtualTranscript
        rows={shown}
        sessionId="find-wake"
        onToggleActivity={noop}
        expanded={new Set()}
        find={withFind}
        anchorNow={anchorNow}
        // The report sink can appear after mount, as a pane's chat becomes known.
        onAnchor={withFind ? (anchor) => reported.push(anchor) : undefined}
        onFollowingChange={(following) => {
          // Hide in Find's own turn, before a subsequent visible placement or scroll event can
          // refresh the wake anchor. A hidden pane must keep the place Find just chose.
          if (!following && hideOnFind) viewport = 0;
        }}
      />,
    );
  try {
    await act(async () => render(rows));
    const atMatch = scroller().scrollTop;
    expect(anchorNow.current?.()).toBeNull();

    jest.useFakeTimers();
    hideOnFind = true;
    await act(async () => render(rows, find));
    expect(viewport).toBe(0);
    const parked = anchorNow.current?.();
    expect(parked).toBeTruthy();
    expect(scroller().scrollTop).toBe(atMatch);
    await act(async () => void jest.advanceTimersByTime(SCROLL_ANCHOR_SETTLE_MS - 1));
    expect(reported).toEqual([]);
    await act(async () => void jest.advanceTimersByTime(1));
    expect(reported).toEqual([parked!]);

    // Stream while hidden, then read the same anchorNow hook pane.wakeState uses. A null value
    // would become atLatest:true and lose the Find position when the page is recreated.
    await act(async () => render(more, find));
    const wake = anchorNow.current?.();
    expect(wake).toEqual(parked);
    await act(async () => root.unmount());
    viewport = VIEWPORT;
    root = createRoot(dom.window.document.getElementById("root")!);
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={more}
          sessionId="find-wake"
          openAt={wake!}
          onToggleActivity={noop}
          expanded={new Set()}
        />,
      ),
    );
    expect(scroller().scrollTop).toBe(atMatch);
  } finally {
    viewport = VIEWPORT;
    await act(async () => root.unmount());
    jest.useRealTimers();
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

test("a Find selection completes placement before a short chat first overflows", async () => {
  const raw = turn(0);
  const rows = turnView(raw, new Set());
  const root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = () => dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
  const height = () => parseFloat(dom.window.document.querySelector<HTMLElement>(".acpmux-spacer")!.style.height);
  const target = rows.findIndex((shown) => shown.id === "t0-user");
  const find: ChatFind = {
    open: true,
    query: "Question 0",
    matches: [{ rowIndex: target, rowId: "t0-user", occurrence: 0 }],
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
    const initialTop = scroller().scrollTop;
    expect(height()).toBeLessThanOrEqual(VIEWPORT);
    await act(async () => render(rows, find));
    expect(scroller().scrollTop).toBe(initialTop);
    await act(async () => render(rows));

    let overflowed = false;
    let rawRows = raw;
    for (let index = 1; index <= 8; index += 1) {
      rawRows = [...rawRows, ...turn(index)];
      const next = turnView(rawRows, new Set());
      await act(async () => render(next));
      if (height() > VIEWPORT) {
        overflowed = true;
        break;
      }
    }
    expect(overflowed).toBe(true);
    // Find chose the reader's place while the transcript fit; first overflow must not reopen it at
    // the latest row and reacquire bottom follow.
    expect(scroller().scrollTop).toBe(initialTop);
  } finally {
    await act(async () => root.unmount());
  }
});
