// The Chat Minimap setting overrides the experiment live: full draws every message under the
// viewport box, compact draws the rail, and off hides both. Clearing the key restores the
// experiment. The host display event carries the key into an already open chat.
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
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
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

// jsdom has no layout: a 600 px viewport in a pane wide enough for any rail (1040 px).
const VIEWPORT = 600;
const PANE = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => PANE });
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
const { MINIMAP_KEY, chatDisplay, resolveThreadMinimapArm, setChatDisplay } =
  await import("../src/agent-session/acpmux/chatDisplay");

afterAll(() => {
  setChatDisplay({});
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

test("the Chat Minimap key is unset by default and only an arm, or the old toggle's value, sets it", () => {
  expect(resolveThreadMinimapArm({})).toBeNull();
  expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: "full" })).toBe("full");
  // The old toggle: on was the full map, off left the chat to the experiment.
  expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: true })).toBe("full");
  expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: false })).toBeNull();
  expect(resolveThreadMinimapArm({ [MINIMAP_KEY]: "yes" })).toBeNull();
});

test("switching the thread minimap preserves the transcript's measured look", () => {
  setChatDisplay({});
  const measuredLook = chatDisplay();
  for (const arm of ["full", "off", "compact"]) {
    setChatDisplay({ [MINIMAP_KEY]: arm });
    expect(chatDisplay()).toBe(measuredLook);
  }
  setChatDisplay({});
});

for (const arm of ["off", "compact"] as const)
  test(`the setting draws the full-height map in an open chat and takes it away again (experiment ${arm})`, async () => {
    (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": arm };
    setChatDisplay({});
    const host = document.createElement("div");
    document.body.append(host);
    const root = createRoot(host);
    const map = () => host.querySelector(".acpmux-scrollmap");
    const rail = () => host.querySelector(".acpmux-minimap__rail:not(.acpmux-scrollmap)");
    try {
      await act(async () =>
        root.render(
          <VirtualTranscript
            rows={turnView(chat(30), new Set())}
            sessionId={`chat-minimap-${arm}`}
            onToggleActivity={() => {}}
            expanded={new Set()}
          />,
        ),
      );
      // Off by default: what the experiment shows, and no map.
      expect(map()).toBeNull();
      expect(rail() !== null).toBe(arm === "compact");
      // Choose Full Map: the host sends the key, and the map has marks and the viewport box.
      await act(async () => setChatDisplay({ [MINIMAP_KEY]: "full" }));
      expect(map()).not.toBeNull();
      expect(host.querySelectorAll(".acpmux-scrollmap__mark").length).toBeGreaterThan(0);
      expect(host.querySelector(".acpmux-scrollmap__view")).not.toBeNull();
      expect(rail()).toBeNull();
      // A settings file the old toggle wrote (`true`) still draws the map.
      await act(async () => setChatDisplay({ [MINIMAP_KEY]: true }));
      expect(map()).not.toBeNull();
      expect(rail()).toBeNull();
      // The row's other value: the rail where the experiment shows none, nothing where it shows the rail.
      await act(async () => setChatDisplay({ [MINIMAP_KEY]: arm === "compact" ? "off" : "compact" }));
      expect(map()).toBeNull();
      expect(rail() !== null).toBe(arm !== "compact");
      // Clear the setting: back to what the experiment shows.
      await act(async () => setChatDisplay({}));
      expect(map()).toBeNull();
      expect(rail() !== null).toBe(arm === "compact");
    } finally {
      await act(async () => root.unmount());
      host.remove();
    }
  });
