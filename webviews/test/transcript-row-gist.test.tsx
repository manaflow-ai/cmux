// l10n-allow-file: test fixture messages, not shipped UI.
// An agent drives the chat through the accessibility tree, where each transcript row (an <article>)
// was labeled only by its speaker ("You", "Agent"), so a message could not be found by its words.
// Each row now carries its first line of text, capped, as its `aria-description`
// (conversation/rowGist.ts); nothing drawn changes.
import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import type { AcpmuxRow } from "../src/agent-session/acpmux/model";
import { ROW_GIST_MAX, rowGist } from "../src/agent-session/acpmux/conversation/rowGist";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";
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
  matchMedia: (query: string) => ({ matches: query.includes("reduce"), media: query }),
  IS_REACT_ACT_ENVIRONMENT: true,
};
// Pierre's registered elements read their own DOM constructors at import time.
for (const key of Object.getOwnPropertyNames(dom.window))
  if (/^(HTML|SVG|CSS|Shadow|Document|Mutation)/.test(key) && !(key in scope))
    replacements[key] = (dom.window as unknown as Record<string, unknown>)[key];
const saved = Object.keys(replacements).map((key) => [key, key in scope, scope[key]] as const);
Object.assign(scope, replacements);
Object.defineProperty(dom.window.HTMLElement.prototype, "clientHeight", { configurable: true, get: () => 600 });
Object.defineProperty(dom.window.HTMLElement.prototype, "clientWidth", { configurable: true, get: () => 1040 });

const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope });
});

const row = (id: string, kind: string, text?: string): AcpmuxRow => ({ id, kind, text, version: 1, at: 1 });

test("a row's gist is its first line of words, without block markers, capped", () => {
  expect(rowGist({ text: "Fix the flaky retry test\nand then run it" })).toBe("Fix the flaky retry test");
  expect(rowGist({ text: "\n\n## Summary\n\nAll green." })).toBe("Summary");
  expect(rowGist({ text: "```ts\nconst x = 1;\n```" })).toBe("const x = 1;");
  expect(rowGist({ text: "> quoted   words\tspaced" })).toBe("quoted words spaced");
  expect(rowGist({ text: "- [x] done item" })).toBe("done item");
  expect(rowGist({ text: "" })).toBeUndefined();
  expect(rowGist({ text: "   \n\t\n" })).toBeUndefined();
  expect(rowGist({})).toBeUndefined();
  const long = rowGist({ text: "word ".repeat(400) })!;
  expect(long.length).toBeLessThanOrEqual(ROW_GIST_MAX);
  expect(long.endsWith("…")).toBe(true);
});

test("each transcript row carries its first line as its aria-description; its label stays the speaker", async () => {
  const rows = [
    row("u1", "user", "Rename the retry helper\nThen run the tests."),
    row("a1", "assistant", "Renamed it to `retryWithBackoff`.\n\nAll 12 tests pass."),
  ];
  const root = createRoot(dom.window.document.getElementById("root")!);
  try {
    await act(async () =>
      root.render(
        <VirtualTranscript rows={turnView(rows, new Set())} onToggleActivity={() => {}} expanded={new Set()} />,
      ),
    );
    const article = (id: string) => dom.window.document.querySelector<HTMLElement>(`article[data-row-id="${id}"]`);
    expect(article("u1")?.getAttribute("aria-description")).toBe("Rename the retry helper");
    expect(article("u1")?.getAttribute("aria-label")).toBe("You");
    expect(article("a1")?.getAttribute("aria-description")).toBe("Renamed it to `retryWithBackoff`.");
  } finally {
    await act(async () => root.unmount());
  }
});
