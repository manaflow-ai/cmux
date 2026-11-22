import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// Highlighting is the costliest thing a reply can ask of the pane. A large fence draws as plain
// monospace text, highlighting runs in a Worker loaded from the page's own origin, and the worker
// is served with a policy that allows it no network.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "Node"];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  customElements: dom.window.customElements,
  Node: dom.window.Node,
});
afterAll(() => Object.assign(globals, saved));

const { createElement } = await import("react");
const { renderToStaticMarkup } = await import("react-dom/server");
const { CodeBlock } = await import("./CodeBlock");
const limits = await import("./highlightLimits");

describe("highlight limits", () => {
  test("an ordinary fence is highlighted", () => {
    expect(renderToStaticMarkup(createElement(CodeBlock, { code: "let a = 1\n", lang: "ts" }))).toContain(
      "<diffs-container",
    );
  });

  test("a fence over the line cap draws as plain monospace text", () => {
    const code = Array.from({ length: limits.MAX_HIGHLIGHT_LINES + 1 }, (_, i) => `line ${i}`).join("\n");
    const html = renderToStaticMarkup(createElement(CodeBlock, { code, lang: "ts" }));
    expect(html).not.toContain("<diffs-container");
    expect(html).toContain("cv-code-plain");
    expect(html).toContain(`line ${limits.MAX_HIGHLIGHT_LINES}`);
  });

  test("a fence over the size cap draws as plain monospace text", () => {
    const code = "x".repeat(limits.MAX_HIGHLIGHT_CHARS + 1);
    const html = renderToStaticMarkup(createElement(CodeBlock, { code, lang: "ts" }));
    expect(html).not.toContain("<diffs-container");
    expect(html).toContain("cv-code-plain");
  });

  test("a long line is tokenized only up to the line cap", () => {
    expect(limits.MAX_TOKENIZED_LINE).toBeLessThanOrEqual(2_000);
    expect(limits.MAX_HIGHLIGHT_LINES).toBeLessThanOrEqual(2_000);
    expect(limits.MAX_HIGHLIGHT_CHARS).toBeLessThanOrEqual(200_000);
  });
});

describe("highlight worker", () => {
  test("the bundled pane highlights in a module worker from its own origin", async () => {
    const { highlightWorkerFactory, usesHighlightWorker } = await import("./highlightPool");
    expect(usesHighlightWorker("cmux-agent:")).toBe(true);
    expect(usesHighlightWorker("cmux-page:")).toBe(true);
    // The dev server serves no built worker; there the pane highlights on the main thread.
    expect(usesHighlightWorker("http:")).toBe(false);
    const made: { url: string; options?: WorkerOptions }[] = [];
    class FakeWorker {
      constructor(url: URL | string, options?: WorkerOptions) {
        made.push({ url: String(url), options });
      }
    }
    highlightWorkerFactory("cmux-agent://pane/index.html", FakeWorker as unknown as typeof Worker)();
    expect(made).toEqual([{ url: "cmux-agent://pane/highlight-worker.js", options: { type: "module" } }]);
  });
});
