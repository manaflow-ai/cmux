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
    computed_styles?: Record<string, string>;
  };
  edits: Array<{ id: string; property: string; original_value: string; value: string }>;
  css_diff: string;
};

type DesignRuntime = {
  enable(): Snapshot;
  destroy(): Snapshot;
  snapshot(): Snapshot;
  select(selector: string, stack?: boolean): Snapshot;
  composerState(): { selection_count: number; selectors: string[] };
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

  test("stores canonical CSS values before mutation reconciliation", () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Hero</h1></main>`);
    const hero = dom.window.document.querySelector("#hero") as HTMLElement;
    runtime.select("#hero");

    const edited = runtime.applyStyle("color", "#fff");

    expect(edited.edits[0]?.value).toBe(hero.style.getPropertyValue("color"));
    expect(edited.css_diff).toContain(`+  color: ${hero.style.getPropertyValue("color")};`);
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
    const recovered = runtime.snapshot();
    expect(recovered.selection?.selector).toBe("#hero");
    expect(recovered.selection?.text_content).toBe("Rerendered");
    expect(recovered.selection?.dom_snippet).toContain("Rerendered");
    expect(recovered.edits.find((edit) => edit.id === "text:text-content")?.original_value).toBe("Rerendered");
    expect(original.style.getPropertyValue("font-size")).toBe("");
    expect(original.textContent).toBe("Original");
  });

  test("reapplies edits when an SPA removes and later reinserts the selected node", async () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Original</h1></main>`);
    runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");
    const original = dom.window.document.querySelector("#hero") as HTMLElement;

    original.remove();
    await new Promise<void>((resolve) => dom.window.setTimeout(resolve, 0));
    expect(runtime.snapshot().selection).toBeNull();

    const elementPrototype = dom.window.Element.prototype;
    const originalQuerySelector = elementPrototype.querySelector;
    let subtreeSelectorQueries = 0;
    Object.defineProperty(elementPrototype, "querySelector", {
      value(this: Element, selector: string) {
        subtreeSelectorQueries += 1;
        return originalQuerySelector.call(this, selector);
      },
    });
    const replacement = dom.window.document.createElement("h1");
    replacement.id = "hero";
    replacement.textContent = "Later render";
    for (let index = 0; index < 100; index += 1) {
      dom.window.document.querySelector("main")?.append(dom.window.document.createElement("span"));
    }
    dom.window.document.querySelector("main")?.append(replacement);
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

    expect(runtime.snapshot().selection?.selector).toBe("#hero");
    expect(replacement.style.getPropertyValue("font-size")).toBe("44px");
    expect(subtreeSelectorQueries).toBe(0);
  });

  test("bounds recovery work when an SPA never recreates the selected node", async () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Original</h1></main>`);
    runtime.select("#hero");
    dom.window.document.querySelector("#hero")?.remove();
    await new Promise<void>((resolve) => dom.window.setTimeout(resolve, 0));

    const originalQuerySelectorAll = dom.window.document.querySelectorAll.bind(dom.window.document);
    let selectorQueries = 0;
    Object.defineProperty(dom.window.document, "querySelectorAll", {
      value: (selector: string) => {
        selectorQueries += 1;
        return originalQuerySelectorAll(selector);
      },
    });
    for (let index = 0; index < 20; index += 1) {
      const unrelated = dom.window.document.createElement("h1");
      unrelated.textContent = `Unrelated ${index}`;
      dom.window.document.querySelector("main")?.append(unrelated);
      await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
      unrelated.remove();
      await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    }

    expect(selectorQueries).toBeLessThanOrEqual(8);
  });

  test("fails closed when a selector is reused by a different element", async () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Original</h1></main>`);
    runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");
    dom.window.document.querySelector("#hero")?.remove();
    await new Promise<void>((resolve) => dom.window.setTimeout(resolve, 0));

    const unrelated = dom.window.document.createElement("button");
    unrelated.id = "hero";
    unrelated.textContent = "Different control";
    dom.window.document.querySelector("main")?.append(unrelated);
    await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));

    expect(runtime.snapshot().selection).toBeNull();
    expect(unrelated.style.getPropertyValue("font-size")).toBe("");
  });

  test("fails closed when a selector is reused by a different logical item", async () => {
    const { dom, runtime } = fixture(`
      <main><button data-testid="save" data-item-key="alpha">Save</button></main>
    `);
    runtime.select('[data-testid="save"]');
    runtime.applyStyle("font-size", "44px");
    const original = dom.window.document.querySelector('[data-testid="save"]') as HTMLElement;
    const replacement = dom.window.document.createElement("button");
    replacement.dataset.testid = "save";
    replacement.dataset.itemKey = "beta";
    replacement.textContent = "Save";

    original.replaceWith(replacement);
    await Promise.resolve();
    await Promise.resolve();

    expect(runtime.snapshot().selection).toBeNull();
    expect(replacement.style.getPropertyValue("font-size")).toBe("");
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

  test("keeps the original baseline when reselecting the edited element", () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Original</h1></main>`);
    const before = runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");
    runtime.applyText("Edited");

    const reselected = runtime.select("#hero");

    expect(reselected.selection?.text_content).toBe("Original");
    expect(reselected.selection?.computed_styles?.["font-size"]).toBe(before.selection?.computed_styles?.["font-size"]);
    runtime.revertAll();
    expect((dom.window.document.querySelector("#hero") as HTMLElement).textContent).toBe("Original");
  });

  test("ignores unrelated DOM churn and reconciles relevant selected mutations", async () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Hero</h1><section id="ticker"></section></main>`);
    const hero = dom.window.document.querySelector("#hero") as HTMLElement;
    const originalSetProperty = hero.style.setProperty.bind(hero.style);
    let styleWrites = 0;
    Object.defineProperty(hero.style, "setProperty", {
      value: (property: string, value: string, priority?: string) => {
        styleWrites += 1;
        originalSetProperty(property, value, priority);
      },
    });
    runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");
    await Promise.resolve();
    await Promise.resolve();
    styleWrites = 0;

    dom.window.document.querySelector("#ticker")?.append(dom.window.document.createElement("span"));
    await Promise.resolve();
    await Promise.resolve();
    expect(styleWrites).toBe(0);

    hero.style.removeProperty("font-size");
    await Promise.resolve();
    await Promise.resolve();
    expect(hero.style.getPropertyValue("font-size")).toBe("44px");
    expect(styleWrites).toBe(1);

    hero.id = "renamed-hero";
    await new Promise<void>((resolve) => dom.window.setTimeout(resolve, 0));
    expect(runtime.snapshot().selection?.selector).toBe("#renamed-hero");
  });

  test("coalesces native snapshots during sustained selected-subtree churn", async () => {
    const { dom, messages, runtime } = fixture(`<main><section id="ticker"></section></main>`);
    runtime.select("#ticker");
    const messagesBeforeChurn = messages.length;
    const ticker = dom.window.document.querySelector("#ticker") as HTMLElement;

    for (let index = 0; index < 6; index += 1) {
      ticker.append(dom.window.document.createComment(`tick ${index}`));
      await Promise.resolve();
      await Promise.resolve();
      await new Promise<void>((resolve) => dom.window.requestAnimationFrame(() => resolve()));
    }

    expect(messages.length - messagesBeforeChurn).toBeLessThanOrEqual(2);
  });

  test("preserves application style and text updates beneath active edits", async () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero" style="color: purple">Original</h1></main>`);
    const hero = dom.window.document.querySelector("#hero") as HTMLElement;
    runtime.select("#hero");
    runtime.applyStyle("color", "red");
    runtime.applyText("Design edit");

    hero.style.setProperty("color", "green");
    hero.textContent = "Application update";
    await Promise.resolve();
    await Promise.resolve();

    expect(hero.style.getPropertyValue("color")).toBe("red");
    expect(hero.textContent).toBe("Design edit");
    runtime.revertAll();
    expect(hero.style.getPropertyValue("color")).toBe("green");
    expect(hero.textContent).toBe("Application update");
  });

  test("restores injected text without removing application-added children", async () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Original</h1></main>`);
    const hero = dom.window.document.querySelector("#hero") as HTMLElement;
    runtime.select("#hero");
    runtime.applyText("Design edit");

    const badge = dom.window.document.createElement("span");
    badge.textContent = "Application badge";
    hero.append(badge);
    await Promise.resolve();
    await Promise.resolve();

    expect(hero.firstChild?.nodeValue).toBe("Original");
    expect(hero.querySelector("span")?.textContent).toBe("Application badge");
    expect(runtime.snapshot().edits).toHaveLength(0);
  });

  test("bounds page-controlled snapshot fields before crossing the bridge", () => {
    const { dom, runtime } = fixture(`<p id="notes"></p>`);
    const huge = "x".repeat(1_000_000);
    const paragraph = dom.window.document.querySelector("#notes") as HTMLParagraphElement;
    paragraph.textContent = "Original";

    const selected = runtime.select("#notes");
    runtime.applyText(huge);
    const edited = runtime.snapshot();

    expect(selected.selection?.text_content?.length).toBeLessThanOrEqual(16 * 1024);
    expect(selected.selection?.dom_snippet?.length).toBeLessThanOrEqual(2400);
    expect(edited.edits[0]?.value.length).toBeLessThanOrEqual(16 * 1024);
    expect(JSON.stringify(edited).length).toBeLessThanOrEqual(128 * 1024);
  });

  test("refuses text editing when the reversible original exceeds the text limit", () => {
    const { dom, runtime } = fixture(`<p id="notes"></p>`);
    const huge = "x".repeat(1_000_000);
    const paragraph = dom.window.document.querySelector("#notes") as HTMLParagraphElement;
    paragraph.textContent = huge;

    const selected = runtime.select("#notes");
    const edited = runtime.applyText("Replacement");

    expect(selected.selection?.text_editable).toBe(false);
    expect(edited.edits).toHaveLength(0);
    expect(paragraph.textContent).toBe(huge);
  });

  test("rejects container text editing without materializing descendant text", () => {
    const { dom, runtime } = fixture(`<main><section id="container"><span>Nested copy</span></section></main>`);
    const container = dom.window.document.querySelector("#container") as HTMLElement;
    let textContentReads = 0;
    Object.defineProperty(container, "textContent", {
      configurable: true,
      get: () => {
        textContentReads += 1;
        return "x".repeat(1_000_000);
      },
    });

    const selected = runtime.select("#container");

    expect(selected.selection?.text_editable).toBe(false);
    expect(textContentReads).toBe(0);
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

  test("redacts accessibility labels on sensitive controls", () => {
    const { runtime } = fixture(`
      <main>
        <input id="otp" type="text" autocomplete="one-time-code"
               aria-label="Verification code sent to austin@example.com">
      </main>
    `);

    const snapshot = runtime.select("#otp");
    expect(snapshot.selection?.dom_snippet).not.toContain("austin@example.com");
    expect(snapshot.selection?.dom_snippet).toContain("&lt;redacted&gt;");
    expect(snapshot.selection?.selector).not.toContain("austin@example.com");
    for (const selector of snapshot.selection?.selectors ?? []) {
      expect(selector).not.toContain("austin@example.com");
    }
  });

  test("redacts editable content and URL-bearing attributes", () => {
    const { runtime } = fixture(`
      <main id="drafts">
        <div id="editor" contenteditable="true">private draft copy</div>
        <div id="role-editor" role="textbox">private role draft</div>
        <a href="https://example.com/reset/opaque-reset-secret">Reset password</a>
        <form action="https://example.com/submit/opaque-action-secret"></form>
      </main>
    `);

    const editor = runtime.select("#editor");
    expect(editor.selection?.text_content).toBe("<redacted>");
    expect(editor.selection?.text_editable).toBe(false);

    const roleEditor = runtime.select("#role-editor");
    expect(roleEditor.selection?.text_content).toBe("<redacted>");
    expect(roleEditor.selection?.text_editable).toBe(false);

    const drafts = runtime.select("#drafts");
    expect(drafts.selection?.dom_snippet).not.toContain("private draft copy");
    expect(drafts.selection?.dom_snippet).not.toContain("private role draft");
    expect(drafts.selection?.dom_snippet).not.toContain("opaque-reset-secret");
    expect(drafts.selection?.dom_snippet).not.toContain("opaque-action-secret");
    expect(drafts.selection?.dom_snippet).toContain("&lt;redacted&gt;");
  });

  test("redacts select and option form data", () => {
    const { runtime } = fixture(`
      <main id="account-form">
        <select name="account">
          <option value="opaque-account-token">Private account label</option>
        </select>
      </main>
    `);

    const select = runtime.select("select");
    expect(select.selection?.text_content).toBe("<redacted>");
    expect(select.selection?.text_editable).toBe(false);
    expect(select.selection?.dom_snippet).not.toContain("opaque-account-token");

    const form = runtime.select("#account-form");
    expect(form.selection?.dom_snippet).not.toContain("opaque-account-token");
    expect(form.selection?.dom_snippet).not.toContain("Private account label");
    expect(form.selection?.text_content).not.toContain("Private account label");
  });

  test("bounds snippet traversal and builds a selection baseline once", () => {
    const { dom, runtime } = fixture(`<main><p id="notes"></p></main>`);
    const notes = dom.window.document.querySelector("#notes") as HTMLElement;
    const nodes = Array.from({ length: 600 }, () => dom.window.document.createTextNode(""));
    notes.append(...nodes);
    let lateNodeReads = 0;
    Object.defineProperty(nodes[550], "nodeValue", {
      configurable: true,
      get: () => {
        lateNodeReads += 1;
        return "";
      },
    });
    const getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
    let computedStyleCalls = 0;
    Object.defineProperty(dom.window, "getComputedStyle", {
      value: (element: Element) => {
        computedStyleCalls += 1;
        return getComputedStyle(element);
      },
    });

    runtime.select("#notes");

    expect(lateNodeReads).toBe(0);
    expect(computedStyleCalls).toBe(1);
  });

  test("does not expose or edit form values or dispatch page input events", () => {
    const { dom, runtime } = fixture(`<main><input id="name" value="Original"></main>`);
    let inputEvents = 0;
    const input = dom.window.document.querySelector("#name") as HTMLInputElement;
    input.addEventListener("input", () => { inputEvents += 1; });

    const selected = runtime.select("#name");
    const edited = runtime.applyText("Edited");
    runtime.revertAll();

    expect(selected.selection?.text_content).toBe("<redacted>");
    expect(selected.selection?.text_editable).toBe(false);
    expect(selected.selection?.dom_snippet).not.toContain("Original");
    expect(edited.edits).toHaveLength(0);
    expect(input.value).toBe("Original");
    expect(inputEvents).toBe(0);
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

  test("revalidates selector uniqueness immediately before capture", () => {
    const { dom, runtime } = fixture(`
      <main><button data-testid="save">Save</button></main><aside></aside>
    `);
    const selected = runtime.select('[data-testid="save"]');
    const duplicate = dom.window.document.createElement("button");
    duplicate.dataset.testid = "save";
    dom.window.document.querySelector("aside")?.append(duplicate);

    const prepared = runtime.prepareCapture();
    const captureSelector = prepared.selection?.selector;

    expect(captureSelector).toBeDefined();
    expect(captureSelector).not.toBe(selected.selection?.selector);
    expect(dom.window.document.querySelectorAll(captureSelector || "")).toHaveLength(1);
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

  test("selects through an interaction shield before the page receives pointer gestures", () => {
    const { dom, runtime } = fixture(`<main><button id="danger">Delete</button></main>`);
    const button = dom.window.document.querySelector("#danger") as HTMLButtonElement;
    const overlay = dom.window.document.querySelector("[data-cmux-design-mode=overlay]") as HTMLElement;
    let pagePointerDowns = 0;
    button.addEventListener("pointerdown", () => { pagePointerDowns += 1; });
    Object.defineProperty(dom.window.document, "elementFromPoint", { value: () => button });

    overlay.dispatchEvent(new dom.window.MouseEvent("pointerdown", {
      bubbles: true,
      cancelable: true,
      button: 0,
      clientX: 4,
      clientY: 4,
    }));

    expect(runtime.snapshot().selection?.selector).toBe("#danger");
    expect(pagePointerDowns).toBe(0);
  });

  test("plain click replaces the selection; shift-click stacks", () => {
    const { dom, runtime } = fixture(`<main><button id="first">A</button><button id="second">B</button></main>`);
    const first = dom.window.document.querySelector("#first") as HTMLButtonElement;
    const second = dom.window.document.querySelector("#second") as HTMLButtonElement;
    let underPoint: HTMLElement = first;
    Object.defineProperty(dom.window.document, "elementFromPoint", { value: () => underPoint });
    const pointerDown = (init: Record<string, unknown> = {}) => dom.window.document.dispatchEvent(
      new dom.window.MouseEvent("pointerdown", { bubbles: true, cancelable: true, button: 0, clientX: 4, clientY: 4, ...init }),
    );

    pointerDown();
    underPoint = second;
    pointerDown();
    let state = runtime.composerState();
    expect(state.selection_count).toBe(1);
    expect(state.selectors).toEqual(["#second"]);

    underPoint = first;
    pointerDown({ shiftKey: true });
    state = runtime.composerState();
    expect(state.selection_count).toBe(2);
    expect(state.selectors).toEqual(["#second", "#first"]);

    underPoint = second;
    pointerDown();
    state = runtime.composerState();
    expect(state.selection_count).toBe(1);
    expect(state.selectors).toEqual(["#second"]);
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
