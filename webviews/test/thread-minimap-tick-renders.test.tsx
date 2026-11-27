// The compact rail's rows render only when what they show changes (ThreadMinimap.tsx TickList): a
// one-row scroll of the rail renders no row it had and the list only when its window moves a step
// (tickWindow.ts, 6 rows), an edited prompt renders its own row, and a hover only the rows its
// magnify grows. The list took the first row in its view as a prop, which changed on every row of a
// scroll and rendered the list each time, and it built each row's list item itself, so every drawn
// row was a new element too (60 of 60, cmux#46148). Counted with the pane's render counter
// (perf.ts `renders`, perfRender.ts).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";
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

// jsdom has no layout: a 600 px pane, wide enough for the rail beside the text.
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 600 });
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
dom.window.HTMLElement.prototype.scrollTo = function (this: HTMLElement, options?: ScrollToOptions | number) {
  this.scrollTop = typeof options === "number" ? 0 : (options?.top ?? 0);
} as typeof HTMLElement.prototype.scrollTo;

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { acpmuxPerf } = await import("../src/agent-session/acpmux/perf");
afterAll(async () => {
  acpmuxPerf.enabled = false;
  await teardownDom(saved, { window: dom.window, scope });
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const chat = (count: number) =>
  Array.from({ length: count }, (_, index) => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", `Answer ${index}.`),
    { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
  ]).flat();

const renders = (name: string) => acpmuxPerf.renders.get(`ThreadMinimap.${name}`) ?? 0;

test("a scroll, an edited prompt and a hover render only the rail's rows they change", async () => {
  const rows = chat(2_000);
  const root = createRoot(document.getElementById("root")!);
  const render = (list: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(list, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
  acpmuxPerf.enabled = true;
  try {
    acpmuxPerf.resetRenders();
    await render(rows);
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    const drawn = () =>
      new Set([...list.querySelectorAll<HTMLElement>("[data-tick]")].map((tick) => tick.dataset.tick));
    // The counter sees each drawn row mount (it counts on this tree).
    expect(drawn().size).toBeGreaterThan(20);
    expect(renders("Tick")).toBeGreaterThanOrEqual(drawn().size);
    const measure = async (event: () => Promise<void>) => {
      const before = drawn();
      acpmuxPerf.resetRenders();
      await event();
      const added = [...drawn()].filter((tick) => !before.has(tick)).length;
      return { list: renders("TickList"), ticks: renders("Tick"), added };
    };
    const pitch = Number.parseFloat(list.style.getPropertyValue("--acpmux-minimap-pitch")) || 10;
    const scrollBy = (by: number) =>
      act(async () => {
        list.scrollTop += by;
        list.dispatchEvent(new dom.window.Event("scroll"));
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(null)));
      });
    // The rail opens at its end: move it up from there first, so a step has room either way.
    await scrollBy(-40 * pitch);

    // Twelve one-row scrolls: two steps of the window. A row it had renders in none; the list renders
    // as the window moves, not on every row.
    const scrolls: Array<{ list: number; ticks: number; added: number }> = [];
    for (let step = 0; step < 12; step += 1) scrolls.push(await measure(() => scrollBy(-pitch)));
    console.log("scroll", JSON.stringify(scrolls));
    for (const each of scrolls) expect(each.ticks).toBe(each.added);
    expect(scrolls.reduce((sum, each) => sum + each.list, 0)).toBeLessThanOrEqual(4);

    // The person edits a prompt in view: its row, and only its row, renders (its label changes).
    const ticks = [...list.querySelectorAll<HTMLElement>("[data-tick]")];
    const middle = Number(ticks[Math.floor(ticks.length / 2)]!.dataset.tick);
    const edited = rows.map((each) =>
      each.id === `t${middle}-user` ? { ...each, text: `${each.text} (edited)`, version: 2 } : each,
    );
    const change = await measure(() => render(edited));
    console.log("change", JSON.stringify(change));
    expect(change.ticks).toBe(1);

    // A hover grows the rows within the magnify's reach (3 each side) and renders no other.
    const target = list.querySelector<HTMLElement>(`[data-tick="${middle}"]`)!;
    const hover = await measure(() =>
      act(async () => {
        target.dispatchEvent(new dom.window.MouseEvent("pointerover", { bubbles: true }));
        target.dispatchEvent(new dom.window.MouseEvent("pointerenter", { bubbles: false }));
      }),
    );
    console.log("hover", JSON.stringify(hover));
    expect(hover.ticks).toBeGreaterThan(0);
    expect(hover.ticks).toBeLessThanOrEqual(7);
  } finally {
    acpmuxPerf.enabled = false;
    await act(async () => root.unmount());
  }
});
