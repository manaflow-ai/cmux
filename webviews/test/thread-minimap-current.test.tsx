// The thread minimap's current turn (cx-f7c): the turn being read is a longer tick in the accent,
// so the reader sees where they are in the thread at a glance (Codex style).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
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

// jsdom has no layout: a 600 px viewport (the transcript's first height) over a long conversation,
// and a scroll offset the test moves as the reader would.
const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
// Wide enough for the minimap's gutter (ThreadMinimap MIN_GUTTER).
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
const jumps: number[] = [];
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  const top = typeof options === "number" ? 0 : (options?.top ?? 0);
  jumps.push(top);
  this.scrollTop = top;
} as typeof HTMLElement.prototype.scrollTo;

const { act, createRef, useLayoutEffect } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { ThreadMinimap } = await import("../src/agent-session/acpmux/threadMinimap/ThreadMinimap");

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const TURNS = 12;
const turns = Array.from({ length: TURNS }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

const scale = (tick: Element) => tick.querySelector<HTMLElement>(".acpmux-minimap__bar")!.style.transform;

test("a tick click and a next-turn command during commit use the new geometry", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  const scroller = createRef<HTMLElement>();
  scroller.current = dom.window.document.createElement("div");
  const rows = [
    row("commit-first", "user", "First"),
    row("commit-second", "user", "Second"),
    row("commit-third", "user", "Third"),
  ];
  const draw = (top: number, duringCommit: boolean) => {
    const layout = {
      tops: Float64Array.from([0, top, 2000]),
      heights: Float64Array.from([top, 2000 - top, 1000]),
      totalHeight: 3000,
    };
    function CommitClick() {
      useLayoutEffect(() => {
        if (!duringCommit) return;
        dom.window.document.querySelector<HTMLButtonElement>('[data-tick="1"]')!.click();
        scroller.current!.scrollTop = 0;
        dom.window.dispatchEvent(new dom.window.Event("cmux-acpmux-nextTurn"));
      });
      return null;
    }
    return act(async () =>
      root.render(
        <>
          <ThreadMinimap
            rows={rows}
            getLayout={() => layout}
            scroller={scroller}
            scrollTop={0}
            viewportHeight={VIEWPORT}
            width={1040}
          />
          <CommitClick />
        </>,
      ),
    );
  };
  try {
    await draw(800, false);
    jumps.length = 0;
    await draw(1200, true);
    expect(jumps).toEqual([1200, 1200]);
  } finally {
    await act(async () => root.unmount());
  }
});

test("the minimap draws the turn being read longer than the others, in the accent", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    const ticks = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")];
    expect(ticks()).toHaveLength(TURNS);
    /// The tick marked as the turn being read; every tick is checked against it.
    const check = () => {
      const current = ticks().findIndex((tick) => tick.getAttribute("aria-current") === "location");
      ticks().forEach((tick, index) => {
        const reading = index === current;
        // The accent and the length: data-current (threadMinimap.css) and a 14 px bar against the 6 px rest.
        expect(tick.dataset.current).toBe(reading ? "" : undefined);
        expect(scale(tick)).toContain(`scaleX(${(reading ? 14 : 6) / 26})`);
      });
      return current;
    };
    // It opens at the latest message: a turn near the end is the one being read.
    expect(check()).toBeGreaterThanOrEqual(TURNS - 2);
    // Scrolled to the top, the first is.
    const scroller = dom.window.document.querySelector<HTMLElement>(".acpmux-scroll")!;
    scroller.scrollTop = 0;
    await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
    expect(check()).toBe(0);
  } finally {
    await act(async () => root.unmount());
  }
});

test("a kept minimap tick jumps using the latest geometry after a reply changes", async () => {
  const { layoutConversation, transcriptRowWidth } = await import("../src/agent-session/acpmux/model");
  const root = createRoot(dom.window.document.getElementById("root")!);
  const expanded = new Set<string>();
  const onToggleActivity = () => {};
  const draw = async (rows: AcpmuxRow[]) => {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} onToggleActivity={onToggleActivity} expanded={expanded} />),
    );
  };
  try {
    await draw(turnView(turns, expanded));
    const changed = turns.map((one, index) =>
      index === 1
        ? {
            ...one,
            version: 2,
            text: "A much longer answer.\n\n".repeat(30),
          }
        : one,
    );
    const rows = turnView(changed, expanded);
    await draw(rows);
    const target = rows.findIndex((one) => one.id === "t4-user");
    const expected = layoutConversation(rows, transcriptRowWidth(1040)).tops[target];
    jumps.length = 0;
    await act(async () => dom.window.document.querySelector<HTMLButtonElement>('[data-tick="4"]')!.click());
    expect(jumps).toEqual([expected]);
  } finally {
    await act(async () => root.unmount());
  }
});
