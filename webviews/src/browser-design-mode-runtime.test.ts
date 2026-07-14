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
  selection: null | {
    selector: string;
    selectors: string[];
    text_content?: string;
    text_editable?: boolean;
    dom_snippet?: string;
  };
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
  prepareCapture(): Snapshot;
  finishCapture(): Snapshot;
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
    const original = dom.window.document.querySelector("#hero") as HTMLElement;
    original.replaceWith(replacement);
    await Promise.resolve();
    await Promise.resolve();

    expect(replacement.style.getPropertyValue("font-size")).toBe("44px");
    expect(replacement.textContent).toBe("Edited heading");
    expect(runtime.snapshot().selection?.selector).toBe("#hero");
    expect(original.style.getPropertyValue("font-size")).toBe("");
    expect(original.textContent).toBe("Original");
  });

  test("fails closed when selection or SPA rebinding is ambiguous", async () => {
    const nested = (label: string) => `<section><div><div><div><div><div><div><div><span class="target">${label}</span></div></div></div></div></div></div></div></section>`;
    const ambiguous = fixture(`<main>${nested("First")}${nested("Second")}</main>`);
    expect(ambiguous.runtime.select(".target").selection).toBeNull();

    const { dom, runtime } = fixture(`<main><h1 id="hero">Original</h1></main>`);
    runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");
    const original = dom.window.document.querySelector("#hero") as HTMLElement;
    const replacements = Array.from({ length: 2 }, (_, index) => {
      const element = dom.window.document.createElement("h1");
      element.id = "hero";
      element.textContent = `Replacement ${index}`;
      return element;
    });
    original.replaceWith(...replacements);
    await Promise.resolve();
    await Promise.resolve();

    expect(runtime.snapshot().selection).toBeNull();
    expect(replacements.every((element) => element.style.getPropertyValue("font-size") === "")).toBe(true);
  });

  test("keeps accumulated edits when a new element cannot be selected uniquely", () => {
    const nested = (label: string) => `<section><div><div><div><div><div><div><div><span class="target">${label}</span></div></div></div></div></div></div></div></section>`;
    const { dom, runtime } = fixture(`<main><h1 id="hero">Hero</h1>${nested("First")}${nested("Second")}</main>`);
    const hero = dom.window.document.querySelector("#hero") as HTMLElement;
    runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");

    const rejected = runtime.select(".target:first-of-type");

    expect(rejected.selection?.selector).toBe("#hero");
    expect(rejected.edits).toHaveLength(1);
    expect(hero.style.getPropertyValue("font-size")).toBe("44px");
  });

  test("bounds page-controlled snapshot fields before crossing the bridge", () => {
    const { dom, runtime } = fixture(`<textarea id="notes"></textarea>`);
    const huge = "x".repeat(1_000_000);
    const textarea = dom.window.document.querySelector("#notes") as HTMLTextAreaElement;
    textarea.value = "Original";

    const selected = runtime.select("#notes");
    runtime.applyText(huge);
    const edited = runtime.snapshot();

    expect(selected.selection?.text_content?.length).toBeLessThanOrEqual(16 * 1024);
    expect(selected.selection?.dom_snippet?.length).toBeLessThanOrEqual(2400);
    expect(edited.edits[0]?.value.length).toBeLessThanOrEqual(16 * 1024);
    expect(JSON.stringify(edited).length).toBeLessThanOrEqual(128 * 1024);
  });

  test("refuses text editing when the reversible original exceeds the text limit", () => {
    const { dom, runtime } = fixture(`<textarea id="notes"></textarea>`);
    const huge = "x".repeat(1_000_000);
    const textarea = dom.window.document.querySelector("#notes") as HTMLTextAreaElement;
    textarea.value = huge;

    const selected = runtime.select("#notes");
    const edited = runtime.applyText("Replacement");

    expect(selected.selection?.text_editable).toBe(false);
    expect(edited.edits).toHaveLength(0);
    expect(textarea.value).toBe(huge);
  });

  test("redacts sensitive form data before snapshots cross the bridge", () => {
    const { runtime } = fixture(`
      <main id="account">
        <input id="password" type="password" value="hunter2">
        <input type="hidden" name="csrf-token" value="secret-token">
        <meta name="csrf-token" content="meta-secret">
        <textarea name="api-token">nested-secret</textarea>
        <textarea name="authToken">camel-auth-secret</textarea>
        <span id="confirmPassword">camel-password-secret</span>
        <span id="sessionId">camel-session-secret</span>
        <script>window.config = "script-secret";</script>
        <style>.style-secret { color: red; }</style>
        <p>Visible account copy</p>
      </main>
    `);

    const password = runtime.select("#password");
    expect(password.selection?.text_content).toBe("<redacted>");
    expect(password.selection?.text_editable).toBe(false);
    expect(password.selection?.dom_snippet).not.toContain("hunter2");

    const account = runtime.select("#account");
    expect(account.selection?.dom_snippet).not.toContain("secret-token");
    expect(account.selection?.dom_snippet).not.toContain("meta-secret");
    expect(account.selection?.dom_snippet).toContain("&lt;redacted&gt;");
    expect(account.selection?.text_content).toContain("Visible account copy");
    expect(account.selection?.text_content).not.toContain("nested-secret");
    expect(account.selection?.text_content).not.toContain("camel-auth-secret");
    expect(account.selection?.text_content).not.toContain("camel-password-secret");
    expect(account.selection?.text_content).not.toContain("camel-session-secret");
    expect(account.selection?.text_content).not.toContain("script-secret");
    expect(account.selection?.text_content).not.toContain("style-secret");
  });

  test("rebinds controlled inputs without redispatching an input loop", async () => {
    const { dom, runtime } = fixture(`<main><input id="name" value="Original"></main>`);
    let inputEvents = 0;
    const replaceOnInput = (event: Event) => {
      inputEvents += 1;
      const current = event.currentTarget as HTMLInputElement;
      const replacement = current.cloneNode(true) as HTMLInputElement;
      replacement.value = "Server value";
      replacement.addEventListener("input", replaceOnInput);
      current.replaceWith(replacement);
    };
    const input = dom.window.document.querySelector("#name") as HTMLInputElement;
    input.addEventListener("input", replaceOnInput);

    runtime.select("#name");
    runtime.applyText("Edited");
    await Promise.resolve();
    await Promise.resolve();

    const replacement = dom.window.document.querySelector("#name") as HTMLInputElement;
    expect(inputEvents).toBe(1);
    expect(replacement.value).toBe("Edited");
  });

  test("prepares capture without depending on animation-frame delivery", () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Hello</h1></main>`);
    runtime.select("#hero");
    let requestedFrames = 0;
    Object.defineProperty(dom.window, "requestAnimationFrame", {
      value: () => {
        requestedFrames += 1;
        return 1;
      },
    });

    const prepared = runtime.prepareCapture();
    expect(prepared.selection?.selector).toBe("#hero");
    expect(requestedFrames).toBe(0);
    runtime.finishCapture();
  });

  test("does not synthesize unique selectors while hovering", async () => {
    const { dom } = fixture(`<main><button class="primary action">Save</button></main>`);
    const button = dom.window.document.querySelector("button") as HTMLElement;
    Object.defineProperty(dom.window.document, "elementFromPoint", { value: () => button });
    const originalQuerySelectorAll = dom.window.document.querySelectorAll.bind(dom.window.document);
    let selectorQueries = 0;
    Object.defineProperty(dom.window.document, "querySelectorAll", {
      value: (selector: string) => {
        selectorQueries += 1;
        return originalQuerySelectorAll(selector);
      },
    });

    button.dispatchEvent(new dom.window.MouseEvent("pointermove", { bubbles: true, clientX: 4, clientY: 4 }));
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

    expect(selectorQueries).toBe(0);
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
