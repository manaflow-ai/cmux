// Leo, 2026-10-14: tooltips and hover cards showed at once (or nearly: the minimap's turn preview
// after 110 ms) on everything the pointer passed. They now share the
// app's hover intent (ui/hoverIntent.ts): the first waits the hover delay (450 ms; AppKit's tooltip
// delay is about 1 s), a neighbor's then shows at once, and half a second away cools it again.
// These run on a fake clock, through the components' own pointer handlers: the delays are the
// behavior, and a loaded runner's late wake-ups must not decide them.
import { afterAll, expect, jest, test } from "bun:test";
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
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);

const VIEWPORT = 600;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });
dom.window.HTMLElement.prototype.scrollTo = function () {} as typeof HTMLElement.prototype.scrollTo;

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

const wait = (ms: number) => act(async () => void jest.advanceTimersByTime(ms));
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const TURNS = 8;
const turns = Array.from({ length: TURNS }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

// The minimap's turn preview opens on the frame the pointer reaches a row, with no dwell (Leo,
// 2026-10-29: "giving it faster scrttoll/hover over"); it was Codex's 250 ms, the app's other cards 450.
test("the minimap's turn preview opens at once and follows the pointer from row to row", async () => {
  const root = createRoot(dom.window.document.getElementById("root")!);
  jest.useFakeTimers();
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(turns, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    const rail = dom.window.document.querySelector<HTMLElement>(".acpmux-minimap__rail")!;
    expect(rail).not.toBeNull();
    const tick = (index: number) => dom.window.document.querySelectorAll<HTMLElement>(".acpmux-minimap__tick")[index]!;
    const popover = () => dom.window.document.querySelector<HTMLElement>(".acpmux-minimap__card");
    const visible = () => popover() !== null && !popover()!.hidden;
    // The rail's rows take the pointer (their pointerenter and pointerleave, which React draws
    // from pointerover and pointerout): onto the rail from outside, then from row to row.
    let under: number | undefined;
    const pointer = (type: string, target: Element, relatedTarget: Element | null) =>
      target.dispatchEvent(new dom.window.MouseEvent(type, { bubbles: true, relatedTarget }));
    const move = (index: number) =>
      act(async () => {
        if (under === undefined) pointer("pointerover", tick(index), dom.window.document.body);
        else if (under !== index) {
          pointer("pointerout", tick(under), tick(index));
          pointer("pointerover", tick(index), tick(under));
        }
        under = index;
      });
    const leave = () =>
      act(async () => {
        if (under !== undefined) pointer("pointerout", tick(under), null);
        under = undefined;
      });
    // Shown as soon as the pointer comes, with no timer to run.
    const opensAtOnce = async (index: number) => {
      await move(index);
      expect(visible()).toBe(true);
    };

    await opensAtOnce(2);
    // The next tick's preview at once.
    await move(3);
    expect(visible()).toBe(true);
    // Off the rail, and back after the warm time: at once again.
    await leave();
    expect(visible()).toBe(false);
    await wait(600);
    await opensAtOnce(4);
  } finally {
    jest.useRealTimers();
    await act(async () => root.unmount());
  }
});
