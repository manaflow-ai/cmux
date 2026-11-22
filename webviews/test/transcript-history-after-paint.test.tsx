// A chat opens with one viewport of history mounted above its view and the rest right after its first
// paint (VirtualTranscript OPEN_HISTORY_VIEWPORTS), so its first commit builds fewer rows.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
import { installJsdomScroller } from "./support/jsdomScroller";
import { teardownDom } from "./support/domTeardown";
import { until } from "./support/until";

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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });
installJsdomScroller(dom.window as never, () => VIEWPORT);

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const turns = Array.from({ length: 30 }, (_, index) => [
  row(`t${index}-user`, "user", `Question ${index}`),
  row(`t${index}-answer`, "assistant", `Answer ${index}.\n\nWith a second paragraph so the turn has height.`),
  { ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 },
]).flat();

test("a chat mounts one viewport of history in its first commit and the rest after its first paint", async () => {
  const rows = turnView(turns, new Set());
  const root = createRoot(dom.window.document.getElementById("root")!);
  const mounted = () => dom.window.document.querySelectorAll("[data-row-id]").length;
  // A turn of the event loop that also lets a frame and the task after it run, and flushes their renders.
  const turn = () => act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  try {
    await act(async () =>
      root.render(<VirtualTranscript rows={rows} sessionId="session-a" onToggleActivity={() => {}} expanded={new Set()} />),
    );
    const first = mounted();
    expect(first).toBeGreaterThan(0);
    // Past the paint (a frame, then a task): the history above the view mounts in full.
    await until(() => mounted() > first * 1.5, turn);
    const full = mounted();
    // Another chat opens the same way: one viewport first, the rest after its paint.
    const other = turnView(
      turns.map((one) => ({ ...one, id: `session-b-${one.id}` })),
      new Set(),
    );
    await act(async () =>
      root.render(<VirtualTranscript rows={other} sessionId="session-b" onToggleActivity={() => {}} expanded={new Set()} />),
    );
    expect(mounted()).toBeLessThan(full * 0.75);
    await until(() => mounted() === full, turn);
  } finally {
    await act(async () => root.unmount());
  }
});
