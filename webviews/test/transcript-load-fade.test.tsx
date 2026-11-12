// l10n-allow-file: the transcript fixture text is test data, not shipped UI.
// Blank to text fades (Leo, 2026-11-07, ask-69299b9711: "going from blank to text is more jarring
// than blank to fast fade in to text"). Rows that land while the chat is still read, after a blank
// or partly blank first paint, fade in once (`cmux-load-fade`). Rows drawn at the first paint never
// fade, a streamed version never restarts it, and rows that arrive once the load is over keep the
// live entrance (or none, for a big batch).
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { teardownDom } from "./support/domTeardown";

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
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

// The load window reads `performance.now()`; the test moves that clock past it instead of waiting.
const realNow = performance.now.bind(performance);
let clockSkew = 0;
performance.now = () => realNow() + clockSkew;

const { act } = await import("react");

const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  performance.now = realNow;
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: "user" | "assistant", text: string, version = 1): AcpmuxRow => ({
  id,
  kind,
  text,
  version,
  at: 1,
});

const turns = (from: number, count: number) =>
  Array.from({ length: count }, (_, index) => {
    const n = from + index;
    return row(`${n % 2 ? "reply" : "prompt"}-${n}`, n % 2 ? "assistant" : "user", `Message ${n}`);
  });

const Row = ({ row: item }: { row: AcpmuxRow }) => <div>{item.text}</div>;
const registry = { user: Row, assistant: Row } as never;

function mount(sessionId: string) {
  const host = dom.window.document.createElement("div");
  dom.window.document.body.append(host);
  const root = createRoot(host);
  const render = (rows: AcpmuxRow[], loading: boolean) =>
    act(async () => {
      root.render(
        <VirtualTranscript
          rows={rows}
          registry={registry}
          sessionId={sessionId}
          onToggleActivity={() => {}}
          expanded={new Set()}
          {...({ loading } as Record<string, unknown>)}
        />,
      );
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  const fading = (id: string) =>
    host.querySelector<HTMLElement>(`[data-row-id="${id}"]`)?.classList.contains("cmux-load-fade");
  const node = (id: string) => host.querySelector<HTMLElement>(`[data-row-id="${id}"]`);
  const unmount = async () => {
    await act(async () => root.unmount());
    host.remove();
  };
  return { render, fading, node, unmount };
}

test("rows that land after a blank first paint while the chat loads fade in once", async () => {
  const view = mount("load-fade-blank");
  try {
    // The page shows the chat before its read is in: nothing to draw yet.
    await render0(view);
    const first = turns(0, 6);
    // The first chunk (more rows than a live update) lands while the chat still loads.
    await view.render(first, true);
    for (const item of first) expect(view.fading(item.id)).toBe(true);
    // A second chunk right after it (the read landing) fades too, rows above and below alike.
    const more = [...turns(100, 4), ...first, ...turns(6, 4)];
    await view.render(more, false);
    for (const item of turns(6, 4)) expect(view.fading(item.id)).toBe(true);
    // Rows above the first chunk fade too: by the load fade, or by the older-history fade a page
    // reaching the reader at the loaded top already takes (OlderRowFade); never both, never none.
    for (const item of turns(100, 4)) {
      const older = view.node(item.id)?.classList.contains("acpmux-row--older");
      expect(older || view.fading(item.id)).toBe(true);
      expect(older && view.fading(item.id)).toBe(false);
    }
    // A streamed version of a faded row keeps its node and its one fade; it never restarts.
    const before = view.node("reply-9");
    const streamed = more.map((item) =>
      item.id === "reply-9" ? { ...item, text: "Message 9 more", version: 2 } : item,
    );
    await view.render(streamed, false);
    expect(view.node("reply-9")).toBe(before);
  } finally {
    await view.unmount();
  }
});

test("rows on screen at the first paint, and rows after the load, never take the load fade", async () => {
  const view = mount("load-fade-ready");
  try {
    const ready = turns(0, 6);
    // Ready at the first paint (a kept tail, or a fast read): drawn whole, never held back.
    await view.render(ready, true);
    for (const item of ready) expect(view.fading(item.id)).toBe(false);
    // The read lands: what it adds under the rows on screen fades in.
    const read = [...ready, ...turns(6, 4)];
    await view.render(read, false);
    for (const item of turns(6, 4)) expect(view.fading(item.id)).toBe(true);
    for (const item of ready) expect(view.fading(item.id)).toBe(false);
    // Past the load's window a live row keeps the live entrance, not the load fade.
    // Well past the load's window (shared/loadFade.ts LOAD_FADE_WINDOW_MS, 600 ms).
    clockSkew += 1000;
    const live = [...read, row("prompt-10", "user", "Live prompt")];
    await view.render(live, false);
    expect(view.fading("prompt-10")).toBe(false);
    expect(view.node("prompt-10")?.classList.contains("acpmux-row--message-enter")).toBe(true);
  } finally {
    await view.unmount();
  }
});

test("a chat that never loaded (a new chat, or loading off) keeps the live entrance", async () => {
  const view = mount("load-fade-off");
  try {
    await view.render([], false);
    await view.render([row("prompt-0", "user", "First prompt")], false);
    expect(view.fading("prompt-0")).toBe(false);
    expect(view.node("prompt-0")?.classList.contains("acpmux-row--message-enter")).toBe(true);
  } finally {
    await view.unmount();
  }
});

const render0 = (view: ReturnType<typeof mount>) => view.render([], true);
