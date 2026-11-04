// The prompt rail's vertical placement. Its box is centered in the transcript's view (model.ts railTop)
// and holds the ticks it draws. Prompts not held yet (the snapshot's `promptCount`, before the prompt
// index answers or on a daemon without one) reserve no empty rows above the held ticks: that pushed the
// held ticks to the box's foot, just above the composer (Leo, 2026-11-01: "what a stupid f***ing choice
// to put the f***ing scroll rail at the bottom???"). The prompt index gives every prompt its tick, so
// the rail is full height once it answers (Leo, 2026-11-01: "i also want the left scroll rail to be
// starting off to its max height if there truly are that many prompts in the chat"). Before it answers,
// the count's prompts draw as pending resting ticks above the held ones (model.ts pendingTurns), so the
// first frame is the final frame: the same length, top and tick rows while history pages in (Leo,
// 2026-11-03: "mostly i just don't like it when the thing shifts and whatnot trying to center itself").
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };

const dom = new JSDOM("<!doctype html><div id=root></div><div id=dock></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const scope = globalThis as Record<string, unknown>;
/// Every ResizeObserver the transcript makes, so a test can say a box changed size.
const observers: { callback: ResizeObserverCallback; self: ResizeObserver }[] = [];
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
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
  IntersectionObserver: class {
    observe() {}
    unobserve() {}
    disconnect() {}
  },
  ResizeObserver: class {
    constructor(callback: ResizeObserverCallback) {
      observers.push({ callback, self: this as unknown as ResizeObserver });
    }
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

// jsdom has no layout: a 700 px view, a pane 1040 px wide, and a bottom stack `stack` px tall laid over
// the view's foot.
const VIEWPORT = 700;
const PANE = 1040;
const stack = 120;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => PANE });
const rect = (top: number, height: number) =>
  ({ top, bottom: top + height, height, left: 0, right: PANE, width: PANE, x: 0, y: top }) as DOMRect;
dom.window.HTMLElement.prototype.getBoundingClientRect = function (this: HTMLElement) {
  if (this.id === "dock") return rect(VIEWPORT - stack, stack);
  if (this.classList.contains("acpmux-composer-box")) return rect(VIEWPORT - stack, stack);
  if (this.classList.contains("acpmux-scroll")) return rect(0, VIEWPORT);
  return rect(0, 0);
};
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

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    row(`user-${index + 1}`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

/// The rail's box and where its latest tick draws, in px down the view.
const rail = () => {
  const nav = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
  const list = nav.querySelector<HTMLElement>(".acpmux-minimap__list")!;
  const ticks = nav.querySelectorAll(".acpmux-minimap__entry, .acpmux-minimap__gap");
  const rows = [...ticks].reduce(
    (sum, node) =>
      sum +
      (node.classList.contains("acpmux-minimap__gap") ? Number.parseFloat((node as HTMLElement).style.height) / 10 : 1),
    0,
  );
  const top = Number.parseFloat(nav.style.top);
  const lead = Number.parseFloat(list.style.marginTop || "0");
  return {
    top,
    lead,
    height: Number.parseFloat(nav.style.height),
    latest: top + lead + (rows - 1) * 10 - list.scrollTop,
  };
};

/// Centered in the view, then moved up only as far as it takes to clear the bottom stack (model.ts railTop).
const centered = (height: number) => Math.round((VIEWPORT - height) / 2);
/// Where the drawn ticks' run is centered, in px down the view.
const middle = (box: ReturnType<typeof rail>) => (box.top + box.lead + box.latest + 10) / 2;

test("held ticks sit centered in the view, never stacked at the box's foot, while older prompts are not held", async () => {
  const all = chat(45);
  const prompts = all.filter((entry) => entry.kind === "user");
  const held = all.slice(all.indexOf(prompts[33]!));
  const earlier = prompts.slice(0, 33).map((entry) => ({ ...entry }));
  const root = createRoot(document.getElementById("root")!);
  const dock = document.getElementById("dock")!;
  const render = (props: { earlier?: AcpmuxRow[]; promptCount?: number }) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(held, new Set())}
          {...props}
          sessionId="rail-full"
          dock={dock}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    // The first frame: twelve prompts held, the summary says forty-five.
    await render({ promptCount: 45 });
    const open = rail();
    // The box is the rail's one height (240 px, the Codex rail's size) over all forty-five ticks, the
    // thirty-three not held yet as resting ticks, centered: no empty rows above the held ones.
    expect(open.lead).toBe(0);
    expect(open.height).toBe(240);
    // Every prompt has its row, drawn or (past the list's view) a gap's.
    const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-minimap__entry, .acpmux-minimap__gap")].reduce(
      (sum, node) =>
        sum + (node.classList.contains("acpmux-minimap__gap") ? Number.parseFloat(node.style.height) / 10 : 1),
      0,
    );
    expect(rows).toBe(45);
    expect(open.top).toBeLessThanOrEqual(centered(240));
    // The ticks' run is about the view's middle, nowhere near its foot.
    expect(Math.abs(middle(open) - VIEWPORT / 2)).toBeLessThanOrEqual(100);
    // The latest tick ends the box, clear of the bottom stack.
    expect(open.latest + 10).toBe(open.top + open.height);
    expect(open.latest + 10).toBeLessThanOrEqual(VIEWPORT - stack);
    // The index answers: every prompt has its tick, in the same box.
    await render({ earlier });
    const full = rail();
    expect(full).toEqual(open);
    expect(full.lead).toBe(0);
    expect(full.height).toBe(240);
    expect(full.top).toBeLessThanOrEqual(centered(240));
    expect(Math.abs(middle(full) - VIEWPORT / 2)).toBeLessThanOrEqual(100);
  } finally {
    await act(async () => root.unmount());
  }
});

test("without a count the rail grows as prompts arrive, as before", async () => {
  const all = chat(45);
  const prompts = all.filter((entry) => entry.kind === "user");
  const held = all.slice(all.indexOf(prompts[33]!));
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(held, new Set())}
          sessionId="rail-grow"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    // Twelve prompts: the rail's one height, centered.
    expect(rail().height).toBe(240);
    expect(rail().top).toBeLessThanOrEqual(centered(240));
  } finally {
    await act(async () => root.unmount());
  }
});

test("a chat with more prompts than the rail holds keeps its latest tick at the box's end once the index arrives", async () => {
  const all = chat(80);
  const prompts = all.filter((entry) => entry.kind === "user");
  const held = all.slice(all.indexOf(prompts[68]!));
  const earlier = prompts.slice(0, 68).map((entry) => ({ ...entry }));
  const root = createRoot(document.getElementById("root")!);
  const dock = document.getElementById("dock")!;
  const render = (props: { earlier?: AcpmuxRow[]; promptCount?: number }) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(held, new Set())}
          {...props}
          sessionId="rail-over"
          dock={dock}
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    await render({ promptCount: 80 });
    // Twelve held and sixty-eight pending: already the rail's final box, with no empty rows.
    const first = rail();
    expect(first.lead).toBe(0);
    await render({ earlier });
    const open = rail();
    expect(open).toEqual(first);
    // Taller than the room: the rail fills it, and the latest tick ends at its bottom.
    expect(open.height).toBeLessThan(800);
    expect(open.latest + 10).toBe(open.top + open.height);
  } finally {
    await act(async () => root.unmount());
  }
});

/// Every frame's rail: its box, the list's offset, how many prompts it draws, and where each held
/// prompt's tick is (by its text, which a pending tick has none of), in px down the view.
const frame = () => {
  const nav = document.querySelector<HTMLElement>("nav.acpmux-minimap__rail")!;
  const list = nav.querySelector<HTMLElement>(".acpmux-minimap__list")!;
  const ticks: Record<string, number> = {};
  for (const tick of nav.querySelectorAll<HTMLElement>("[data-tick]")) {
    const prompt = tick.getAttribute("aria-label")?.match(/Question \d+/)?.[0];
    if (prompt) ticks[prompt] = Number.parseFloat(nav.style.top) + Number(tick.dataset.tick) * 10 - list.scrollTop;
  }
  return {
    top: Number.parseFloat(nav.style.top),
    height: Number.parseFloat(nav.style.height),
    scrollTop: list.scrollTop,
    prompts: Number(nav.querySelector("[aria-setsize]")?.getAttribute("aria-setsize")),
    ticks,
  };
};

for (const count of [45, 80])
  test(`a ${count}-prompt chat whose rows load in pages draws the same rail on every frame`, async () => {
    const all = chat(count);
    const prompts = all.filter((entry) => entry.kind === "user");
    /// The rows held once `pages` pages of twelve prompts have loaded above the latest twelve.
    const heldAfter = (pages: number) => all.slice(all.indexOf(prompts[Math.max(0, count - 12 * (pages + 1))]!));
    const root = createRoot(document.getElementById("root")!);
    const dock = document.getElementById("dock")!;
    const frames: ReturnType<typeof frame>[] = [];
    const render = async (rows: AcpmuxRow[], props: { earlier?: AcpmuxRow[]; promptCount?: number }) => {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={turnView(rows, new Set())}
            {...props}
            sessionId={`rail-pages-${count}`}
            dock={dock}
            onToggleActivity={() => {}}
            expanded={new Set()}
          />,
        ),
      );
      frames.push(frame());
    };
    try {
      // The first frame: the latest page and the summary's count (direct.ts promptCountAwaited).
      await render(heldAfter(0), { promptCount: count });
      // A page loads above it before the index answers.
      await render(heldAfter(1), { promptCount: count });
      // The index answers (the count goes with it), then the rest of the pages load.
      const held = heldAfter(1);
      const firstHeld = prompts.findIndex((entry) => held.includes(entry));
      await render(held, { earlier: prompts.slice(0, firstHeld).map((entry) => ({ ...entry })) });
      for (let pages = 2; 12 * (pages + 1) < count + 12; pages += 1) {
        const rows = heldAfter(pages);
        const from = prompts.findIndex((entry) => rows.includes(entry));
        await render(rows, from > 0 ? { earlier: prompts.slice(0, from).map((entry) => ({ ...entry })) } : {});
      }
      const last = frames.at(-1)!;
      expect(last.prompts).toBe(count);
      for (const each of frames) {
        // The same box, list offset and prompt count as the final frame.
        expect({ ...each, ticks: undefined }).toEqual({ ...last, ticks: undefined });
        // Every prompt drawn on both frames sits on the same row.
        for (const [prompt, y] of Object.entries(each.ticks))
          if (prompt in last.ticks) expect([prompt, y]).toEqual([prompt, last.ticks[prompt]!]);
      }
    } finally {
      await act(async () => root.unmount());
    }
  });
