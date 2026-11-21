// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A row that arrives outside a pane drag writes no style on the row before it.
//
// #41446 let a pane drag flow the chat's mounted rows, and for that each row's render carried the
// gap under it as an inline custom property. The gap of the row before an arriving row changes as
// the row arrives, so every arrival wrote that row's style, and the page styled all it holds again
// (a custom property inherits). In WebKit under load an arriving reply then drew over the row
// before it for a frame more often (test/agent-pane-stream-row-overlap.test.ts, "webkit:
// followed, lagging": 8 first tries of 15 against 1 of 15 without it).
//
// The gap under a row is drawn by the row's own gap child (`.acpmux-row__gap`), which does change
// at an arrival. The row's element itself is placed by `top` and `margin-top` alone, and an arrival
// under it moves neither: so this counts the writes of the row's `style` attribute across an
// arrival, with no drag, and wants none. The flow's gap is written by the transcript when the rows
// start to flow (VirtualTranscript `anchorFlow`), which test/support/transcriptDragStays.ts covers
// in both engines.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
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
  Range: dom.window.Range,
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
  getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
  requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
  cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  IS_REACT_ACT_ENVIRONMENT: true,
};
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation|KeyboardEvent|CustomEvent)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 10_000 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 760 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
const { defaultRegistry } = await import("../src/agent-session/acpmux/rows/registry");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

let n = 0;
const row = (kind: string, fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id: fields.id ?? `${kind}-${(n += 1)}`,
  version: 1,
  at: (n += 1) * 1000,
  kind,
  ...fields,
});
const run = (command: string): AcpmuxActivity => ({
  kind: "tool",
  text: command,
  tool: { id: `tool-${(n += 1)}`, title: command, kind: "execute", status: "completed", command, output: "ok\n" },
});
const prompt = row("user", { id: "prompt", text: "Look around" });
const calls = row("activity", { id: "calls", items: [run("git status")], toolCount: 1 });
const reply = row("assistant", { id: "reply", text: "Done looking around." });

/// The inline height of a row's gap child: what the row draws under itself ("" for none).
const gapUnder = (article: HTMLElement) =>
  article.querySelector<HTMLElement>(":scope > .acpmux-row__gap")!.style.height;

// `gapMustChange`: this arrival is known to change the gap under the row before it (a prompt has
// room under it once a reply follows), so the case proves that the count is of an arrival that did
// change that row's gap. A run's line can sit close to the row before it; each case prints its gap.
for (const [name, before, arriving, gapMustChange] of [
  ["a reply under the prompt", [prompt], reply, true],
  ["a run's line under the prompt", [prompt], calls, false],
  ["a reply under a run's line", [prompt, calls], reply, false],
] as const)
  test(`${name}: the arrival writes no style on the row before it`, async () => {
    const host = dom.window.document.createElement("div");
    dom.window.document.body.append(host);
    const root = createRoot(host);
    const render = (rows: readonly AcpmuxRow[]) =>
      act(async () => {
        root.render(
          <VirtualTranscript
            rows={[...rows]}
            registry={defaultRegistry}
            sessionId={`arrival-row-style-${name}`}
            onToggleActivity={() => {}}
            expanded={new Set<string>()}
          />,
        );
        await new Promise((resolve) => setTimeout(resolve, 0));
      });
    try {
      await render(before);
      // Once more, the same rows: what the first mount still had to place is placed.
      await render(before);
      const last = before.at(-1)!;
      const article = host.querySelector<HTMLElement>(`[data-row-id="${last.id}"]`)!;
      expect(article.classList.contains("acpmux-row")).toBe(true);
      const styleBefore = article.getAttribute("style");
      const gapBefore = gapUnder(article);
      let writes = 0;
      const watch = new dom.window.MutationObserver((records) => {
        writes += records.length;
      });
      watch.observe(article, { attributes: true, attributeFilter: ["style"] });

      await render([...before, arriving]);
      writes += watch.takeRecords().length;
      watch.disconnect();

      const same = host.querySelector<HTMLElement>(`[data-row-id="${last.id}"]`);
      // Compared as a boolean: a failing DOM node prints the whole jsdom window.
      expect(same === article, "the row before the arriving one keeps its element").toBe(true);
      expect(host.querySelector(`[data-row-id="${arriving.id}"]`) !== null, "the arriving row is drawn").toBe(true);
      const gapAfter = gapUnder(article);
      console.log(
        `transcript-arrival-row-style: ${name} ${JSON.stringify({ gapBefore, gapAfter, writes, style: article.getAttribute("style") })}`,
      );
      if (gapMustChange) expect(gapAfter, "the gap under the row before, once a row follows it").not.toBe(gapBefore);
      expect(writes, "writes of the style attribute of the row before the arriving one").toBe(0);
      expect(article.getAttribute("style"), "the style of the row before the arriving one").toBe(styleBefore);
    } finally {
      await act(async () => root.unmount());
      host.remove();
    }
  });
