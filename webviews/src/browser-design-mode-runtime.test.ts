import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { JSDOM } from "jsdom";

const runtimeSource = readFileSync(
  new URL("../../Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Resources/BrowserDesignModeRuntime.js", import.meta.url),
  "utf8",
);

const doms: JSDOM[] = [];

function fixture(html: string, options: { stallAnimationFrames?: boolean } = {}) {
  const messages: unknown[] = [];
  const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true, url: "http://localhost:3000" });
  doms.push(dom);
  let overlayShadowRoot: ShadowRoot | null = null;
  const attachShadow = dom.window.Element.prototype.attachShadow;
  dom.window.Element.prototype.attachShadow = function(init: ShadowRootInit) {
    const root = attachShadow.call(this, init);
    if (this.getAttribute("data-cmux-design-mode") === "overlay") overlayShadowRoot = root;
    return root;
  };
  if (options.stallAnimationFrames) {
    Object.defineProperty(dom.window, "requestAnimationFrame", { value: () => 1 });
  }
  Object.defineProperty(dom.window, "webkit", {
    value: { messageHandlers: { cmuxDesignMode: { postMessage: (value: unknown) => messages.push(value) } } },
  });
  dom.window.eval(runtimeSource);
  const runtime = (dom.window as unknown as { __cmuxDesignMode: DesignRuntime }).__cmuxDesignMode;
  runtime.enable();
  return { dom, messages, overlayShadowRoot: () => overlayShadowRoot, runtime };
}

type SnapshotSelection = {
  selector: string;
  selectors: string[];
  xpath?: string;
  tag_name?: string;
  react_components?: string[];
  react_prop_keys?: string[];
  text_content?: string;
  text_editable?: boolean;
  dom_snippet?: string;
  computed_styles?: Record<string, string>;
  bounds?: { x: number; y: number; width: number; height: number };
};

type Snapshot = {
  enabled: boolean;
  selection: null | SnapshotSelection;
  selections?: SnapshotSelection[];
  edits: Array<{ id: string; property: string; original_value: string; value: string }>;
  css_diff: string;
};

type DesignRuntime = {
  enable(): Snapshot;
  destroy(): Snapshot;
  snapshot(): Snapshot;
  select(selector: string, stack?: boolean): Snapshot;
  composerState(): {
    selection_count: number;
    selectors: string[];
    can_copy: boolean;
    mode: string;
    hovered_selector: string | null;
    annotation_phase: "idle" | "drawing" | "ink_only" | "capturing" | "captured";
  };
  setMode(mode: string): Snapshot;
  setSelectionHover(selection: number | string | null): Snapshot;
  clearHover(): Snapshot;
  flashSelection(index: number): Snapshot;
  removeSelection(selection: number | string): Snapshot;
  applyStyle(property: string, value: string): Snapshot;
  applyText(value: string): Snapshot;
  revert(id: string): Snapshot;
  revertAll(): Snapshot;
  prepareCapture(): Snapshot;
  finishCapture(): Snapshot;
  prepareAnnotationCapture(id: string): {
    id: string;
    stroke_bounds: { x: number; y: number; width: number; height: number };
    viewport: { width: number; height: number };
    scroll_x: number;
    scroll_y: number;
  } | null;
  completeAnnotationCapture(
    id: string,
    x: number,
    y: number,
    width: number,
    height: number,
    imageURL: string,
    expectedScrollX: number,
    expectedScrollY: number,
    expectedViewportWidth: number,
    expectedViewportHeight: number,
  ): Snapshot;
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

  test("selects deep twins via a unique path but fails closed on ambiguous SPA rebinding", async () => {
    // Twin subtrees deeper than the structural walk: selection still succeeds
    // because the nth-child path fallback uniquely names one of them.
    const nested = (label: string) => `<section><div><div><div><div><div><div><div><span class="target">${label}</span></div></div></div></div></div></div></div></section>`;
    const ambiguous = fixture(`<main>${nested("First")}${nested("Second")}</main>`);
    const picked = ambiguous.runtime.select(".target");
    expect(picked.selection).not.toBeNull();
    const pickedSelector = picked.selection?.selector ?? "";
    const matches = ambiguous.dom.window.document.querySelectorAll(pickedSelector);
    expect(matches.length).toBe(1);
    expect((matches[0] as HTMLElement).textContent).toBe("First");

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

  test("keeps accumulated edits when a select targets nothing", () => {
    const { dom, runtime } = fixture(`<main><h1 id="hero">Hero</h1></main>`);
    const hero = dom.window.document.querySelector("#hero") as HTMLElement;
    runtime.select("#hero");
    runtime.applyStyle("font-size", "44px");

    const rejected = runtime.select(".does-not-exist");

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

  test("prepares and restores capture without depending on animation-frame delivery", () => {
    const { dom, overlayShadowRoot, runtime } = fixture(`<main><h1 id="hero">Hello</h1></main>`);
    runtime.select("#hero");
    runtime.setSelectionHover(0);
    const outline = Array.from(overlayShadowRoot()?.querySelectorAll("div") ?? []).find(
      (element) => element.style.borderColor === "rgb(10, 132, 255)"
        && element.style.position === "fixed",
    );
    expect(outline?.style.display).toBe("block");
    let requestedFrames = 0;
    Object.defineProperty(dom.window, "requestAnimationFrame", {
      value: () => {
        requestedFrames += 1;
        return 1;
      },
    });

    const prepared = runtime.prepareCapture();
    expect(prepared.selection?.selector).toBe("#hero");
    expect(outline?.style.display).toBe("none");
    expect(requestedFrames).toBe(0);
    runtime.finishCapture();
    // Copy restoration must be synchronous so native can keep its visual
    // shield up until WebKit confirms the restored overlay has painted.
    expect(outline?.style.display).toBe("block");
    expect(requestedFrames).toBe(0);
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

    for (const name of ["pointerdown", "pointerup"]) {
      overlay.dispatchEvent(new dom.window.MouseEvent(name, {
        bubbles: true,
        cancelable: true,
        button: 0,
        clientX: 4,
        clientY: 4,
      }));
    }

    expect(runtime.snapshot().selection?.selector).toBe("#danger");
    expect(pagePointerDowns).toBe(0);
  });

  test("selects elements whose class selectors are ambiguous beyond the structural walk depth", () => {
    // Two identical deeply nested subtrees (deeper than the 7-level
    // structural-selector walk) with repeated classes, like search-result
    // rows. Nothing short of a full path disambiguates the second target.
    const row = (label: string) =>
      `<div class="res"><div class="a"><div class="b"><div class="c"><div class="d"><div class="e"><div class="f"><div class="g"><cite class="url x y">${label}</cite></div></div></div></div></div></div></div></div>`;
    const { dom, runtime } = fixture(`<main>${row("first")}${row("second")}</main>`);
    const targets = dom.window.document.querySelectorAll("cite");
    const second = targets[1] as HTMLElement;
    Object.defineProperty(dom.window.document, "elementFromPoint", { value: () => second });
    for (const name of ["pointerdown", "pointerup"]) {
      dom.window.document.dispatchEvent(
        new dom.window.MouseEvent(name, { bubbles: true, cancelable: true, button: 0, clientX: 4, clientY: 4 }),
      );
    }
    const state = runtime.composerState();
    expect(state.selection_count).toBe(1);
    const snapshot = runtime.snapshot();
    const selector = snapshot.selections?.[0]?.selector ?? "";
    expect(selector).not.toBe("");
    expect(dom.window.document.querySelector(selector)).toBe(second);
  });

  test("freehand ink becomes a captured context card only after native capture completes", () => {
    const { dom, messages, runtime } = fixture(`<main><button id="b">B</button></main>`);
    const doc = dom.window.document;
    const at = (name: string, x: number, y: number) => doc.dispatchEvent(
      new dom.window.MouseEvent(name, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y }),
    );

    expect(runtime.composerState().mode).toBe("select");
    runtime.setMode("draw");

    // A freehand stroke whose farthest sweep goes beyond where the pointer is
    // released: the region must bound the WHOLE stroke, not the endpoints.
    at("pointerdown", 10, 20);
    expect(runtime.composerState().annotation_phase).toBe("drawing");
    at("pointermove", 40, 50);
    at("pointermove", 210, 340);
    at("pointerup", 110, 140);

    // Completion is ink-only: no region token/card exists until the native
    // screenshot callback returns the exact composited artifact.
    const inkOnly = runtime.composerState();
    expect(inkOnly.annotation_phase).toBe("ink_only");
    expect(inkOnly.selection_count).toBe(0);
    expect(inkOnly.can_copy).toBe(false);
    const requestMessage = messages.slice().reverse().find(
      (message) => (message as { type?: string }).type === "annotation_capture_requested",
    ) as { request: { id: string } } | undefined;
    expect(requestMessage).toBeDefined();
    const annotationID = requestMessage?.request.id ?? "";

    const descriptor = runtime.prepareAnnotationCapture(annotationID);
    expect(runtime.composerState().annotation_phase).toBe("capturing");
    expect(descriptor?.stroke_bounds).toEqual({ x: 10, y: 20, width: 200, height: 320 });
    const completed = runtime.completeAnnotationCapture(
      annotationID,
      0,
      0,
      258,
      408,
      "data:image/png;base64,Y2FyZA==",
      descriptor?.scroll_x ?? 0,
      descriptor?.scroll_y ?? 0,
      descriptor?.viewport.width ?? 0,
      descriptor?.viewport.height ?? 0,
    );

    expect(runtime.composerState().annotation_phase).toBe("captured");
    expect(runtime.composerState().selection_count).toBe(1);
    expect(runtime.composerState().can_copy).toBe(true);
    const selection = completed.selections?.[0];
    expect(selection?.tag_name).toBe("region");
    expect(selection?.selector).toBe(`@annotation(${annotationID})`);
    expect(selection?.bounds).toEqual({ x: 0, y: 0, width: 258, height: 408 });

    // The trailing click from the same gesture must not add an element selection.
    at("click", 110, 140);
    expect(runtime.composerState().selection_count).toBe(1);

    // One stroke is one immutable context artifact. A later stroke stacks a
    // new request/card rather than merging into or replacing the first.
    // A deliberate one-axis stroke is still an annotation; it does not need
    // circle-like width and height to become a context artifact.
    at("pointerdown", 300, 300);
    at("pointermove", 360, 300);
    at("pointerup", 360, 300);
    const secondRequest = messages.slice().reverse().find(
      (message) => (message as { type?: string }).type === "annotation_capture_requested"
        && (message as { request?: { id?: string } }).request?.id !== annotationID,
    ) as { request: { id: string } } | undefined;
    expect(secondRequest).toBeDefined();
    const secondDescriptor = runtime.prepareAnnotationCapture(secondRequest?.request.id ?? "");
    const regions = runtime.completeAnnotationCapture(
      secondRequest?.request.id ?? "",
      252,
      252,
      156,
      96,
      "data:image/png;base64,Y2FyZDI=",
      secondDescriptor?.scroll_x ?? 0,
      secondDescriptor?.scroll_y ?? 0,
      secondDescriptor?.viewport.width ?? 0,
      secondDescriptor?.viewport.height ?? 0,
    ).selections ?? [];
    expect(regions).toHaveLength(2);
    expect(regions[1]?.bounds?.x).toBe(252);

    const remaining = runtime.removeSelection(regions[0]?.selector ?? "").selections ?? [];
    expect(remaining).toHaveLength(1);
    expect(remaining[0]?.selector).toBe(regions[1]?.selector);

    // Escape clears regions before exiting design mode.
    doc.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
    expect(runtime.composerState().selection_count).toBe(0);
  });

  test("native annotation completion presents the card when an earlier animation frame is stalled", () => {
    const { dom, messages, overlayShadowRoot, runtime } = fixture(
      `<main><button id="b">B</button></main>`,
      { stallAnimationFrames: true },
    );
    const doc = dom.window.document;
    const at = (name: string, x: number, y: number) => doc.dispatchEvent(
      new dom.window.MouseEvent(name, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y }),
    );

    runtime.setMode("draw");
    at("pointerdown", 50, 60);
    at("pointermove", 150, 160);
    at("pointerup", 150, 160);
    const request = messages.slice().reverse().find(
      (message) => (message as { type?: string }).type === "annotation_capture_requested",
    ) as { request: { id: string } } | undefined;
    const descriptor = runtime.prepareAnnotationCapture(request?.request.id ?? "");
    const completed = runtime.completeAnnotationCapture(
      request?.request.id ?? "",
      2,
      12,
      196,
      196,
      "data:image/png;base64,Y2FyZA==",
      descriptor?.scroll_x ?? 0,
      descriptor?.scroll_y ?? 0,
      descriptor?.viewport.width ?? 0,
      descriptor?.viewport.height ?? 0,
    );

    const card = Array.from(overlayShadowRoot()?.querySelectorAll("div") ?? []).find(
      (element) => element.style.backgroundImage.includes("Y2FyZA=="),
    );
    expect(card).toBeDefined();
    expect(card?.style.display).toBe("block");
    expect(card?.style.left).toBe("2px");
    expect(card?.style.top).toBe("12px");
    expect(card?.style.width).toBe("196px");
    expect(card?.style.height).toBe("196px");
    expect(card?.style.borderStyle).toBe("dashed");
    expect(card?.style.borderColor).toBe("rgb(10, 132, 255)");

    runtime.setSelectionHover(completed.selections?.[0]?.selector ?? "");
    expect(card?.style.boxShadow).toContain("rgba(10, 132, 255, 0.55)");
    runtime.setSelectionHover(null);
    expect(card?.style.boxShadow).not.toContain("rgba(10, 132, 255, 0.55)");
  });

  test("annotation cards evict the oldest retained image after the bounded stack fills", () => {
    const { dom, messages, runtime } = fixture(`<main><button>B</button></main>`);
    const doc = dom.window.document;
    const at = (name: string, x: number, y: number) => doc.dispatchEvent(
      new dom.window.MouseEvent(name, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y }),
    );

    runtime.setMode("draw");
    let firstSelector = "";
    let lastSelector = "";
    for (let index = 0; index < 10; index += 1) {
      at("pointerdown", 20 + index, 20 + index);
      at("pointermove", 60 + index, 60 + index);
      at("pointerup", 60 + index, 60 + index);
      const request = messages.slice().reverse().find(
        (message) => (message as { type?: string }).type === "annotation_capture_requested",
      ) as { request: { id: string } } | undefined;
      const annotationID = request?.request.id ?? "";
      const descriptor = runtime.prepareAnnotationCapture(annotationID);
      const snapshot = runtime.completeAnnotationCapture(
        annotationID,
        0,
        0,
        128,
        128,
        `data:image/png;base64,Y2FyZC0${index}`,
        descriptor?.scroll_x ?? 0,
        descriptor?.scroll_y ?? 0,
        descriptor?.viewport.width ?? 0,
        descriptor?.viewport.height ?? 0,
      );
      const selector = snapshot.selections?.at(-1)?.selector ?? "";
      if (index === 0) firstSelector = selector;
      lastSelector = selector;
    }

    const selectors = runtime.snapshot().selections?.map((selection) => selection.selector) ?? [];
    expect(selectors).toHaveLength(8);
    expect(selectors).not.toContain(firstSelector);
    expect(selectors).toContain(lastSelector);
  });

  test("a drag switches select mode to draw while clicks remain element picks", () => {
    const { dom, messages, runtime } = fixture(`<main><button id="b">B</button></main>`);
    const doc = dom.window.document;
    const button = doc.querySelector("#b") as HTMLElement;
    Object.defineProperty(doc, "elementFromPoint", { value: () => button });
    const at = (name: string, x: number, y: number) => doc.dispatchEvent(
      new dom.window.MouseEvent(name, { bubbles: true, cancelable: true, button: 0, clientX: x, clientY: y }),
    );

    // A click in select mode remains an element pick.
    at("pointerdown", 10, 10);
    at("pointerup", 10, 10);
    expect(runtime.snapshot().selection?.selector).toBe("#b");
    expect(runtime.snapshot().selections?.every((entry) => entry.tag_name !== "region")).toBe(true);

    // Crossing the drag threshold automatically enters draw mode before the
    // drawing transaction begins, with the existing element pill preserved.
    at("pointerdown", 40, 40);
    at("pointermove", 140, 140);
    at("pointerup", 140, 140);
    expect(runtime.composerState().mode).toBe("draw");
    expect(runtime.composerState().selection_count).toBe(1);
    const modeMessageIndex = messages.findIndex(
      (message) => (message as { type?: string; mode?: string }).type === "interaction_mode_changed"
        && (message as { mode?: string }).mode === "draw",
    );
    const drawingMessageIndex = messages.findIndex(
      (message) => (message as { type?: string }).type === "annotation_drawing",
    );
    expect(modeMessageIndex).toBeGreaterThanOrEqual(0);
    expect(drawingMessageIndex).toBeGreaterThan(modeMessageIndex);

    // Draw-mode taps remain no-ops; the stroke above becomes a second,
    // region context only after native capture completion.
    at("pointerdown", 30, 30);
    at("pointerup", 31, 31);
    expect(runtime.composerState().selection_count).toBe(1);
    const request = messages.slice().reverse().find(
      (message) => (message as { type?: string }).type === "annotation_capture_requested",
    ) as { request: { id: string } } | undefined;
    const descriptor = runtime.prepareAnnotationCapture(request?.request.id ?? "");
    const selections = runtime.completeAnnotationCapture(
      request?.request.id ?? "",
      0,
      0,
      188,
      188,
      "data:image/png;base64,Y2FyZA==",
      descriptor?.scroll_x ?? 0,
      descriptor?.scroll_y ?? 0,
      descriptor?.viewport.width ?? 0,
      descriptor?.viewport.height ?? 0,
    ).selections ?? [];
    expect(selections).toHaveLength(2);
    expect(selections[0]?.selector).toBe("#b");
    expect(selections[1]?.tag_name).toBe("region");
  });

  test("selection captures React component identity but never prop values", () => {
    const { dom, runtime } = fixture(`<main><button id="b">B</button></main>`);
    const button = dom.window.document.querySelector("#b") as HTMLElement;
    function ResultCard() {}
    function SearchList() {}
    const fiber = {
      type: "button",
      memoizedProps: { children: "B" },
      return: {
        type: ResultCard,
        memoizedProps: { title: "Card", userEmail: "s3cr3t-user-data", children: null },
        return: { type: SearchList, memoizedProps: {}, return: null },
      },
    };
    (button as unknown as Record<string, unknown>)["__reactFiber$abc123"] = fiber;

    const snap = runtime.select("#b");

    expect(snap.selection?.react_components).toEqual(["ResultCard", "SearchList"]);
    expect(snap.selection?.react_prop_keys).toEqual(["title", "userEmail"]);
    expect(JSON.stringify(snap)).not.toContain("s3cr3t-user-data");
  });

  test("selections carry an absolute xpath and support hover-clear and flash", () => {
    const { dom, runtime } = fixture(`<main><section><button id="b">B</button><button class="plain">C</button></section></main>`);
    const plain = dom.window.document.querySelector(".plain") as HTMLElement;

    const withId = runtime.select("#b");
    expect(withId.selection?.xpath).toBe('//*[@id="b"]');

    const positional = runtime.select(".plain");
    expect(positional.selection?.xpath).toBe("/html[1]/body[1]/main[1]/section[1]/button[2]");

    Object.defineProperty(dom.window.document, "elementFromPoint", { value: () => plain });
    dom.window.document.dispatchEvent(
      new dom.window.MouseEvent("pointermove", { bubbles: true, cancelable: true, clientX: 4, clientY: 4 }),
    );
    expect(runtime.composerState().hovered_selector).not.toBeNull();
    runtime.clearHover();
    expect(runtime.composerState().hovered_selector).toBeNull();

    // Flash is a no-op snapshot round-trip in DOM without WAAPI.
    expect(runtime.flashSelection(0).selection?.selector).toBe(positional.selection?.selector);
  });

  test("xpath never anchors on sensitive, quoted, or duplicate ids", () => {
    const { runtime } = fixture(`<main>
      <section><div id='q"uote'><button class="a">A</button></div></section>
      <section><div id="user-password-field"><button class="b">B</button></div></section>
      <section><div id="dup"><button class="c">C</button></div><div id="dup"></div></section>
    </main>`);

    const quoted = runtime.select(".a");
    expect(quoted.selection?.xpath).not.toContain('q"uote');
    expect(quoted.selection?.xpath?.startsWith("/html[1]")).toBe(true);

    const sensitive = runtime.select(".b");
    expect(sensitive.selection?.xpath).not.toContain("password");
    expect(sensitive.selection?.xpath?.startsWith("/html[1]")).toBe(true);

    const duplicate = runtime.select(".c");
    expect(duplicate.selection?.xpath).not.toContain("dup");
    expect(duplicate.selection?.xpath?.startsWith("/html[1]")).toBe(true);
  });

  test("escape clears the selection first, then requests design-mode exit", () => {
    const { dom, messages, runtime } = fixture(`<main><button id="b">B</button></main>`);
    runtime.select("#b");
    const exitRequests = () => messages.filter((m) => (m as { type?: string }).type === "exit_requested");
    const esc = () => dom.window.document.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }),
    );

    esc();
    expect(runtime.composerState().selection_count).toBe(0);
    expect(exitRequests()).toHaveLength(0);
    // The first escape also tells the composer to reset its typed prompt.
    expect(messages.filter((m) => (m as { type?: string }).type === "prompt_reset")).toHaveLength(1);

    esc();
    expect(exitRequests()).toHaveLength(1);
  });

  test("every click stacks the element as another prompt token", () => {
    const { dom, runtime } = fixture(`<main><button id="first">A</button><button id="second">B</button></main>`);
    const first = dom.window.document.querySelector("#first") as HTMLButtonElement;
    const second = dom.window.document.querySelector("#second") as HTMLButtonElement;
    let underPoint: HTMLElement = first;
    Object.defineProperty(dom.window.document, "elementFromPoint", { value: () => underPoint });
    const click = () => {
      for (const name of ["pointerdown", "pointerup"]) {
        dom.window.document.dispatchEvent(
          new dom.window.MouseEvent(name, { bubbles: true, cancelable: true, button: 0, clientX: 4, clientY: 4 }),
        );
      }
    };

    click();
    underPoint = second;
    click();
    let state = runtime.composerState();
    expect(state.selection_count).toBe(2);
    expect(state.selectors).toEqual(["#first", "#second"]);

    // Re-clicking an already stacked element does not duplicate it.
    click();
    state = runtime.composerState();
    expect(state.selection_count).toBe(2);
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
