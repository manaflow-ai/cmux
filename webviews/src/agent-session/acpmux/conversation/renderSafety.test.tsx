import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

// A reply is untrusted text that stays in history: whatever it holds, drawing it must not take the
// pane down, now or on the next load. Deep nesting is capped in the parser, a message that still
// throws draws as its plain text, and the pane has a last boundary of its own.
const dom = new JSDOM("<!doctype html><div id=root></div>", {
  url: "http://localhost/",
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "Node", "IS_REACT_ACT_ENVIRONMENT"];
const saved = Object.fromEntries(keys.map((key) => [key, globals[key]]));
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  // Code cards load @pierre/diffs, which defines its web component at import.
  customElements: dom.window.customElements,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(async () => {
  // React finishes scheduled work on a timer; let it run before the DOM globals go away.
  await new Promise((resolve) => setTimeout(resolve, 20));
  Object.assign(globals, saved);
});

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { renderToStaticMarkup } = await import("react-dom/server");
const { Markdown, parseMarkdown } = await import("./Markdown");
type Block = ReturnType<typeof parseMarkdown>[number];

/// The deepest nesting of quotes and lists in `blocks`.
function depthOf(blocks: Block[]): number {
  let deepest = 0;
  for (const block of blocks) {
    if (block.type === "blockquote") deepest = Math.max(deepest, 1 + depthOf(block.children));
    if (block.type === "list") for (const item of block.items) deepest = Math.max(deepest, 1 + depthOf(item.children));
  }
  return deepest;
}

const deepList = Array.from({ length: 800 }, (_, i) => `${"  ".repeat(i)}- level ${i}`).join("\n");
const deepQuote = `${">".repeat(1600)} bottom of the well`;

describe("nesting depth", () => {
  test("800 nested list levels parse to a bounded depth, and the deep text stays as text", () => {
    const blocks = parseMarkdown(deepList);
    expect(depthOf(blocks)).toBeLessThanOrEqual(32);
    const html = renderToStaticMarkup(createElement(Markdown, null, deepList));
    expect(html).toContain("level 0");
    expect(html).toContain("level 799");
  });

  test("1600 nested quotes parse to a bounded depth and draw", () => {
    expect(depthOf(parseMarkdown(deepQuote))).toBeLessThanOrEqual(32);
    expect(renderToStaticMarkup(createElement(Markdown, null, deepQuote))).toContain("bottom of the well");
  });

  test("ordinary nesting is unchanged", () => {
    const blocks = parseMarkdown("> quote\n> > inner\n\n- a\n  - b\n    - c");
    expect(depthOf(blocks)).toBe(3);
  });
});

describe("data URL images", () => {
  const png = (length: number) => `data:image/png;base64,${"A".repeat(length)}`;

  test("a small data URL image draws", () => {
    expect(renderToStaticMarkup(createElement(Markdown, null, `![dot](${png(64)})`))).toContain('<img class="cv-img"');
  });

  test("a data URL image over the size cap draws as its name, without the URL", () => {
    const html = renderToStaticMarkup(createElement(Markdown, null, `![huge](${png(3_000_000)})`));
    expect(html).not.toContain("<img");
    expect(html).toContain("huge");
    expect(html.length).toBeLessThan(10_000);
  });
});

describe("error boundaries", () => {
  const Throws = () => {
    throw new Error("render failed");
  };
  const quiet = async (run: () => Promise<void>) => {
    const error = console.error;
    console.error = () => {};
    try {
      await run();
    } finally {
      console.error = error;
    }
  };

  test("a message that throws draws as escaped plain text with a note", async () => {
    const { MessageBoundary } = await import("./MessageBoundary");
    const container = dom.window.document.getElementById("root")!;
    const root = createRoot(container);
    await quiet(() =>
      act(async () =>
        root.render(
          createElement(
            "div",
            null,
            createElement(MessageBoundary, { source: "<img src=x onerror=alert(1)> **bold**" }, createElement(Throws)),
            createElement("p", { id: "sibling" }, "next message"),
          ),
        ),
      ),
    );
    expect(container.querySelector("img")).toBeNull();
    expect(container.textContent).toContain("<img src=x onerror=alert(1)> **bold**");
    expect(container.textContent).toContain("could not be rendered");
    // The rest of the transcript still draws.
    expect(container.querySelector("#sibling")?.textContent).toBe("next message");
    await act(async () => root.unmount());
  });

  test("the pane's last boundary draws a notice instead of a blank pane", async () => {
    const { PaneBoundary } = await import("../PaneBoundary");
    const container = dom.window.document.getElementById("root")!;
    const root = createRoot(container);
    await quiet(() => act(async () => root.render(createElement(PaneBoundary, null, createElement(Throws)))));
    expect(container.textContent?.trim()).not.toBe("");
    expect(container.querySelector("button")).not.toBeNull();
    await act(async () => root.unmount());
  });
});
