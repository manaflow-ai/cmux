// The wave rail at the bottom of a long chat (Leo 2026-10-22: "I said it looked too short because
// it wouldn't show the highlighted bottom text where I was scrolling at the bottom, and it just
// didn't go to the bottom. It didn't show the bottom bits being highlighted."). A rail with more
// prompts than room scrolls its own list; that list kept only the band's first row in view, so the
// prompts below it, the chat's last ones among them, sat under the bottom fade or past the rail's
// end. The whole band now shows, clear of the fades, and at the bottom of the chat the list reaches
// its own end with the last ticks lit.
import { afterAll, expect, test } from "bun:test";
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
/// The rail's list clamps its offset as a browser does: rows are 10 px, the list as tall as the rail.
const listRoom = (node: HTMLElement) =>
  Math.max(0, node.childElementCount * 10 - Number.parseFloat(node.parentElement?.style.height ?? "0"));
Object.defineProperty(dom.window.HTMLElement.prototype, "scrollTop", {
  configurable: true,
  get(this: object) {
    return offsets.get(this) ?? 0;
  },
  set(this: HTMLElement, value: number) {
    offsets.set(
      this,
      this.classList.contains("acpmux-minimap__list") ? Math.max(0, Math.min(listRoom(this), value)) : value,
    );
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
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
/// More prompts than the rail has room for (64 rows, 70% of the window, the transcript's height).
const TURNS = 90;
const turns = Array.from({ length: TURNS }, (_, index) => [
  row(`user-${index + 1}`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

/// The 2.5rem fade the list draws at an edge with more rows past it (threadMinimap.css).
const FADE = 40;

test("the band shows whole while the reader scrolls down, and reaches the rail's end at the bottom", async () => {
  const document = dom.window.document;
  const root = createRoot(document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(turns, new Set())}
          sessionId="minimap-bottom"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const rail = () => document.querySelector<HTMLElement>(".acpmux-minimap__rail")!;
    const list = () => document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    // It opens at the latest message: that offset is the bottom of the chat.
    const bottom = scroller.scrollTop;
    expect(bottom).toBeGreaterThan(0);
    expect(rail()).not.toBeNull();
    const height = Number.parseFloat(rail().style.height);
    // The rail's rows scroll: there are more than it has room for.
    expect(TURNS * 10).toBeGreaterThan(height);
    /// Where each lit tick draws in the rail, checked to be inside it and clear of any fade.
    const check = (at: number) => {
      const node = list();
      const current = [...node.querySelectorAll<HTMLElement>('[data-tick][aria-current="true"]')].map((tick) =>
        Number(tick.dataset.tick),
      );
      expect(current.length).toBeGreaterThan(0);
      const top = node.hasAttribute("data-fade-top") ? FADE : 0;
      const end = height - (node.hasAttribute("data-fade-bottom") ? FADE : 0);
      for (const index of current) {
        const y = index * 10 - node.scrollTop;
        if (y < top || y + 10 > end)
          throw new Error(
            `at ${at} px the lit tick ${index} draws at ${y} px, outside ${top} to ${end} px of the rail`,
          );
      }
      return current;
    };
    const scrollTo = async (top: number) => {
      scroller.scrollTop = top;
      await act(async () => void scroller.dispatchEvent(new dom.window.Event("scroll")));
    };
    // Up to the top, then down in wheel-sized steps to the bottom, as a reader goes back down a chat.
    await scrollTo(0);
    expect(check(0)[0]).toBe(0);
    for (let top = 0; top < bottom; top += 120) {
      await scrollTo(top);
      check(top);
    }
    // From two-thirds of the way down, straight back to the bottom.
    await scrollTo(Math.round(bottom * 0.66));
    check(Math.round(bottom * 0.66));
    await scrollTo(bottom);
    // At the bottom the last prompt is lit, the list is at its own end, and no fade is over it.
    expect(check(bottom).at(-1)).toBe(TURNS - 1);
    expect(list().scrollTop + height).toBe(TURNS * 10);
    expect(list().hasAttribute("data-fade-bottom")).toBe(false);
  } finally {
    await act(async () => root.unmount());
  }
});
