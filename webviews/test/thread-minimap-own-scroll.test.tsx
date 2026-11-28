// A scroll event at the offset the rail itself just wrote (a chat switch placing the list, with no
// pointer over the rail) commits nothing: the rail's list handler flushed synchronously on every
// scroll event, and that flushSync rendered every pending update of the pane before the frame
// painted, 7-10 ms inside each chat switch's first frame (settled-page bench, chat_switch). A scroll
// to a new offset still commits in its event (ThreadMinimap.tsx, the list's onScroll).
import { afterAll, expect, mock, test } from "bun:test";
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

const reactDom = await import("react-dom");
// Held before the mock: bun patches the module in place, so reactDom.flushSync becomes the mock itself.
const realFlushSync = reactDom.flushSync;
const flushes = { count: 0 };
await mock.module("react-dom", () => ({
  ...reactDom,
  flushSync: (fn?: () => unknown) => {
    flushes.count += 1;
    return realFlushSync(fn as () => unknown);
  },
}));

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
afterAll(async () => {
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

test("the rail's own scroll write flushes nothing; a scroll to a new offset still commits in its event", async () => {
  const root = createRoot(document.getElementById("root")!);
  await act(async () =>
    root.render(
      <VirtualTranscript rows={turnView(chat(400), new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
    ),
  );
  try {
    const list = document.querySelector<HTMLElement>(".acpmux-minimap__list")!;
    expect(list).toBeTruthy();
    const pitch = Number.parseFloat(list.style.getPropertyValue("--acpmux-minimap-pitch")) || 10;
    const scrollBy = (by: number) =>
      act(async () => {
        list.scrollTop += by;
        list.dispatchEvent(new dom.window.Event("scroll"));
        await new Promise((resolve) => dom.window.requestAnimationFrame(() => resolve(null)));
      });
    // A scroll to a new offset: the rail learns it in its event (a flush).
    flushes.count = 0;
    await scrollBy(-40 * pitch);
    expect(flushes.count).toBeGreaterThanOrEqual(1);
    // The same offset again, as the event a write the rail already drew sends: no flush.
    flushes.count = 0;
    await scrollBy(0);
    expect(flushes.count).toBe(0);
    // And a further scroll still commits in its event.
    flushes.count = 0;
    await scrollBy(-3 * pitch);
    expect(flushes.count).toBeGreaterThanOrEqual(1);
  } finally {
    await act(async () => root.unmount());
  }
});
