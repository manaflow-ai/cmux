// cmux-web-test-timeout: 300
// The wave rail while a reply streams (#24058 review round 3). Every streamed token gives the
// transcript a new rows snapshot, and the rail used to map every prompt again for each one: its
// list of ticks rebuilt each tick's label and element, O(prompts) work per token on the main thread
// in a long chat. The ticks now come from a list that changes only when the prompts do (model.ts
// minimapTurns' `ticks`), so a token in the last reply leaves every tick alone, while the preview
// card still reads the reply as it streams.
import { afterAll, expect, setDefaultTimeout, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
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
  // Reduce Motion: scrolls land at once, so a test reads where they land.
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

// The pane's strings, with a count of every tick label the rail builds (one per tick it renders).
let labels = 0;
const english: Record<string, string> = {
  "minimap.label": "Messages",
  "minimap.moveRight": "",
  "minimap.moveLeft": "",
};
for (const key of ["minimap.tick", "minimap.tickBookmarked"])
  Object.defineProperty(english, key, {
    enumerable: true,
    get: () => {
      labels += 1;
      return "Message {index} of {count}: {prompt}";
    },
  });
const strings = globalThis as { __cmuxPaneStrings?: Record<string, Record<string, string>> };
const stringsBefore = strings.__cmuxPaneStrings;
strings.__cmuxPaneStrings = { en: english };

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { setBookmarkTransport } = await import("../src/agent-session/acpmux/threadMinimap/bookmarks");
// No marks in this chat; acpmux answers at once.
setBookmarkTransport({
  get: async (sessionId) => ({ sessionId, bookmarks: [] }),
  set: async (sessionId) => ({ sessionId, bookmarks: [] }),
});

afterAll(() => {
  setBookmarkTransport(undefined);
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
  if (stringsBefore) strings.__cmuxPaneStrings = stringsBefore;
  else delete strings.__cmuxPaneStrings;
  delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
});

const document = dom.window.document;
const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });
const PROMPTS = 300;
/// A long chat whose last reply is `reply` so far.
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

test("a token streaming into the last reply of a 300-prompt chat builds no tick again", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  // One row array per snapshot, as the store hands them: every row but the streaming one is the
  // same object from snapshot to snapshot.
  const base = chat("Streaming");
  const at = base.findIndex((item) => item.id === `t${PROMPTS - 1}-answer`);
  const render = (reply: string) => {
    const rows = base.slice();
    rows[at] = { ...base[at]!, text: reply, version: reply.length };
    return act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(rows, new Set())}
          sessionId="minimap-stream"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  };
  try {
    let reply = "Streaming";
    await render(reply);
    expect(host.querySelectorAll("[data-tick]").length).toBe(PROMPTS);
    // The rail drew each tick once.
    expect(labels).toBeGreaterThanOrEqual(PROMPTS);
    const perToken: number[] = [];
    for (let token = 0; token < 20; token += 1) {
      reply += ` word${token}`;
      labels = 0;
      await render(reply);
      perToken.push(labels);
    }
    // No tick is built again for a token: the ticks show the prompts, and no prompt changed.
    expect(Math.max(...perToken)).toBe(0);
    expect(host.querySelectorAll("[data-tick]").length).toBe(PROMPTS);

    // The card still previews the reply as it streams.
    const last = host.querySelector<HTMLElement>(`[data-tick="${PROMPTS - 1}"]`)!;
    await act(async () => last.focus());
    reply += " latest";
    await render(reply);
    expect(host.querySelector(".acpmux-minimap__card")?.textContent).toContain("latest");
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});

test("a new prompt adds its tick, and the earlier ones keep theirs", async () => {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  const rows = chat("Done");
  const render = (list: AcpmuxRow[]) =>
    act(async () =>
      root.render(
        <VirtualTranscript
          rows={turnView(list, new Set())}
          sessionId="minimap-stream-prompt"
          onToggleActivity={() => {}}
          expanded={new Set()}
        />,
      ),
    );
  try {
    await render(rows);
    const first = host.querySelector(`[data-tick="0"]`);
    await render([...rows, row(`user-${PROMPTS + 1}`, "user", "One more question")]);
    expect(host.querySelectorAll("[data-tick]").length).toBe(PROMPTS + 1);
    expect(host.querySelector(`[data-tick="${PROMPTS}"]`)?.getAttribute("aria-label")).toContain("One more question");
    // The earlier ticks are the same elements.
    expect(host.querySelector(`[data-tick="0"]`)).toBe(first);
  } finally {
    await act(async () => root.unmount());
    host.remove();
  }
});
