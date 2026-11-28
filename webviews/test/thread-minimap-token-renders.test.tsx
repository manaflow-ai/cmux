// cmux-web-test-timeout: 300
// The prompt rail while a reply streams: a token that only grows the live reply renders no rail.
// Every token gives the transcript new rows and a new layout (the reply's row grows), and the rail
// used to take both as props, so it rendered once per token (~0.7 ms each in a 100k-row chat
// profile) though it drew the same ticks and band. It now holds a stable handle on them
// (MinimapSource) and renders only when a prompt, a tick or the band of prompts on screen changes,
// and draws what a fresh rail of the same chat draws.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";
import { railFrame } from "./support/railFrame";
(globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "thread-minimap-layout": "compact" };
setDefaultTimeout(120_000);

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

// jsdom has no layout: a 600 px viewport in a 1040 px pane, and a scroll offset.
const VIEWPORT = 600;
const paneWidth = 1040;
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => VIEWPORT });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => paneWidth });
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

// The rail's right-click menu labels its filters on every render of the rail: reading the first
// filter's string counts the rail's renders.
let renders = 0;
const english: Record<string, string> = {
  "minimap.label": "Messages",
  "minimap.moveRight": "",
  "minimap.moveLeft": "",
  "minimap.tick": "Message {index} of {count}: {prompt}",
  "minimap.tickBookmarked": "Message {index} of {count}: {prompt}",
};
Object.defineProperty(english, "minimap.filterAll", {
  enumerable: true,
  get: () => {
    renders += 1;
    return "All";
  },
});
const strings = globalThis as { __cmuxPaneStrings?: Record<string, Record<string, string>> };
const stringsBefore = strings.__cmuxPaneStrings;
strings.__cmuxPaneStrings = { en: english };

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { turnView } = await import("../src/agent-session/acpmux/conversation/turns");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
setBookmarkTransport({
  get: async (sessionId) => ({ sessionId, bookmarks: [] }),
  set: async (sessionId) => ({ sessionId, bookmarks: [] }),
});

afterAll(async () => {
  setBookmarkTransport(undefined);
  await teardownDom(saved, { window: dom.window, scope });
  if (stringsBefore) strings.__cmuxPaneStrings = stringsBefore;
  else delete strings.__cmuxPaneStrings;
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const PROMPTS = 300;
/// A last reply long enough to fill the card's preview and the view, so the tokens after it change
/// neither the preview nor the band of prompts on screen: only the reply's height and the chat's.
const LONG_REPLY = Array.from(
  { length: 40 },
  (_, index) => `Paragraph ${index} of the live reply, long enough to wrap across the column a few times over.`,
).join("\n\n");
const chat = (reply: string) =>
  Array.from({ length: PROMPTS }, (_, index) => {
    const last = index === PROMPTS - 1;
    const answer = last ? reply : `Answer ${index}.\n\nWith a second paragraph so the turn has height.`;
    return [
      row(`user-${index + 1}`, "user", `Question ${index}`),
      row(`t${index}-answer`, "assistant", answer),
      ...(last ? [] : [{ ...row(`t${index}-end`, "turnSummary"), status: "completed", durationMs: 1_000 }]),
    ];
  }).flat();

/// What the rail draws: its box, and each drawn tick's row, label, tone and marks.
const drawnRail = (host: HTMLElement) => {
  const rail = host.querySelector<HTMLElement>(".acpmux-minimap");
  const list = host.querySelector<HTMLElement>(".acpmux-minimap__list");
  return {
    box: rail
      ? { top: list?.parentElement?.style.top, height: list?.parentElement?.style.height, side: rail.dataset.side }
      : undefined,
    listTop: list?.scrollTop,
    ticks: [...host.querySelectorAll<HTMLElement>("[data-tick]")].map((tick) => ({
      tick: tick.dataset.tick,
      label: tick.getAttribute("aria-label"),
      tone: tick.dataset.tone,
      bookmarked: tick.dataset.bookmarked,
      incoming: tick.dataset.incoming,
    })),
  };
};

test("30 tokens into the last reply of a 300-prompt chat render the rail no more than what it draws changes", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const base = chat(LONG_REPLY);
  const at = base.findIndex((item) => item.id === `t${PROMPTS - 1}-answer`);
  const rowsFor = (reply: string) => {
    const rows = base.slice();
    rows[at] = { ...base[at]!, text: reply, version: reply.length };
    return rows;
  };
  const view = (rows: AcpmuxRow[], sessionId: string) => (
    <VirtualTranscript
      rows={turnView(rows, new Set())}
      sessionId={sessionId}
      onToggleActivity={() => {}}
      expanded={new Set()}
    />
  );
  let reply = LONG_REPLY;
  let mounted = root;
  try {
    await act(async () => root.render(view(rowsFor(reply), "minimap-token-renders")));
    await railFrame();
    expect(host.querySelectorAll("[data-tick]").length).toBeGreaterThan(0);
    const before = drawnRail(host);
    renders = 0;
    for (let token = 0; token < 30; token += 1) {
      reply += ` word${token}`;
      await act(async () => root.render(view(rowsFor(reply), "minimap-token-renders")));
      await railFrame();
    }
    const after = drawnRail(host);
    // The band of prompts on screen stayed on the live turn and no prompt changed, so the rail draws
    // what it drew before the tokens, and nothing called for a render of it (base: one per token).
    expect(after).toEqual(before);
    expect(renders).toBe(0);

    // A fresh rail of the final chat draws the same ticks and box.
    await act(async () => root.unmount());
    mounted = createRoot(host);
    const fresh = mounted;
    await act(async () => fresh.render(view(rowsFor(reply), "minimap-token-renders")));
    await railFrame();
    expect(drawnRail(host)).toEqual(after);
  } finally {
    await act(async () => mounted.unmount());
    host.remove();
  }
});
