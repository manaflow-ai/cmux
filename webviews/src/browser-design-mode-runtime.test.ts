import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const runtimeSource = readFileSync(
  new URL("../../Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Resources/BrowserDesignModeRuntime.js", import.meta.url),
  "utf8",
);

const doms: JSDOM[] = [];

function fixture(html: string) {
  const messages: unknown[] = [];
  const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true, url: "http://localhost:3000" });
  doms.push(dom);
  Object.defineProperty(dom.window, "webkit", {
    value: { messageHandlers: { cmuxDesignMode: { postMessage: (value: unknown) => messages.push(value) } } },
  });
  dom.window.eval(runtimeSource);
  const runtime = (dom.window as unknown as { __cmuxDesignMode: DesignRuntime }).__cmuxDesignMode;
  runtime.enable();
  return { dom, messages, runtime };
}

type Snapshot = {
  enabled: boolean;
  selection: null | { selector: string; selectors: string[] };
  edits: Array<{ id: string; property: string; original_value: string; value: string }>;
  css_diff: string;
};

type DesignRuntime = {
  enable(): Snapshot;
  destroy(): Snapshot;
  snapshot(): Snapshot;
  select(selector: string): Snapshot;
  applyStyle(property: string, value: string): Snapshot;
  applyText(value: string): Snapshot;
  revert(id: string): Snapshot;
  revertAll(): Snapshot;
};

afterEach(() => {
  for (const dom of doms.splice(0)) dom.window.close();
});

describe("browser design-mode runtime", () => {
  test("generates a stable unique selector and accumulates revertible CSS edits", () => {
    const { dom, runtime } = fixture(`
      <main><button data-testid="save" style="color: purple">Save</button><button>Cancel</button></main>
    `);

    const selected = runtime.select('[data-testid="save"]');
    expect(selected.selection?.selector).toBe('button[data-testid="save"]');
    expect(selected.selection?.selectors).toContain('button[data-testid="save"]');

    runtime.applyStyle("padding-left", "18px");
    const edited = runtime.applyStyle("color", "rgb(1, 2, 3)");
    const button = dom.window.document.querySelector("[data-testid=save]") as HTMLElement;
    expect(button.style.getPropertyValue("padding-left")).toBe("18px");
    expect(edited.edits).toEqual([
      expect.objectContaining({ id: "style:padding-left", property: "padding-left", value: "18px" }),
      expect.objectContaining({ id: "style:color", property: "color", value: "rgb(1, 2, 3)" }),
    ]);
    expect(edited.css_diff).toContain("+  padding-left: 18px;");
    expect(edited.css_diff).toContain("+  color: rgb(1, 2, 3);");

    runtime.revert("style:padding-left");
    expect(button.style.getPropertyValue("padding-left")).toBe("");
    expect(button.style.getPropertyValue("color")).toBe("rgb(1, 2, 3)");
    expect(runtime.snapshot().edits).toHaveLength(1);

    runtime.revertAll();
    expect(button.style.getPropertyValue("color")).toBe("purple");
    expect(runtime.snapshot().edits).toHaveLength(0);
  });

  test("reapplies edits when an SPA replaces the selected node", async () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Original</h1></main>`);
    runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");
    runtime.applyText("Edited heading");

    const replacement = dom.window.document.createElement("h1");
    replacement.id = "hero";
    replacement.textContent = "Rerendered";
    dom.window.document.querySelector("#hero")?.replaceWith(replacement);
    await Promise.resolve();
    await Promise.resolve();

    expect(replacement.style.getPropertyValue("font-size")).toBe("44px");
    expect(replacement.textContent).toBe("Edited heading");
    expect(runtime.snapshot().selection?.selector).toBe("#hero");
  });

  test("reverts form text through the page input event path", () => {
    const { dom, runtime } = fixture(`<input id="name" value="Original">`);
    const input = dom.window.document.querySelector("#name") as HTMLInputElement;
    const values: string[] = [];
    input.addEventListener("input", () => values.push(input.value));

    runtime.select("#name");
    runtime.applyText("Edited");
    runtime.revert("text:text-content");

    expect(input.value).toBe("Original");
    expect(values).toEqual(["Edited", "Original"]);
  });

  test("destroy restores every touched node and removes injected DOM state", () => {
    const { dom, runtime } = fixture(`<main><p class="lede" style="color: purple">Hello</p></main>`);
    const paragraph = dom.window.document.querySelector(".lede") as HTMLElement;
    runtime.select(".lede");
    runtime.applyStyle("color", "rgb(1, 2, 3)");
    runtime.applyText("Changed");

    const finalSnapshot = runtime.destroy();

    expect(finalSnapshot.enabled).toBe(false);
    expect(paragraph.style.getPropertyValue("color")).toBe("purple");
    expect(paragraph.textContent).toBe("Hello");
    expect(dom.window.document.querySelector("[data-cmux-design-mode=overlay]")).toBeNull();
    expect((dom.window as unknown as { __cmuxDesignMode?: unknown }).__cmuxDesignMode).toBeUndefined();
  });
});
