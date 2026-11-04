import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextViewer, type ContextPart, type ContextOverrideScope, type ContextSettings } from "./ContextViewer";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/",
  });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const parts: ContextPart[] = [
  {
    id: "base",
    label: "Harness base",
    source: "Claude Code",
    text: "Read first and work concurrently.",
    tokenCount: 7,
    measurement: "measured",
  },
  {
    id: "cmux",
    label: "cmux guidance",
    source: "cmux",
    text: "Use parallel tool calls.",
    tokenCount: 5,
    measurement: "estimated",
    scope: "user",
  },
];

async function renderViewer(
  container: HTMLElement,
  onSaveOverride?: (scope: ContextOverrideScope, text: string, partId?: string) => void | Promise<void>,
  settings: ContextSettings = { user: null, project: null, defaultText: "Use parallel tool calls." },
) {
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ContextViewer
        parts={parts}
        harness="Claude"
        totalTokens={12}
        settings={settings}
        onSaveOverride={onSaveOverride}
      />,
    );
  });
}

test("labels each effective part and token total, expanding exact text", async () => {
  const container = installDom();
  await renderViewer(container);
  expect(container.querySelector(".acpmux-context-viewer__heading")?.textContent).toContain("12 tokens");
  expect(container.querySelectorAll("[data-part-id]")).toHaveLength(2);
  expect(container.querySelector('[data-part-id="base"] .acpmux-context-part__source')?.textContent).toBe(
    "Claude Code",
  );
  expect(container.querySelector('[data-part-id="base"] .acpmux-context-part__tokens')?.textContent).toBe(
    "7 tokens · measured",
  );
  expect(container.textContent).not.toContain("Read first and work concurrently.");
  await act(async () => container.querySelector<HTMLButtonElement>('[data-part-id="base"] button')!.click());
  expect(container.textContent).toContain("Read first and work concurrently.");
  expect(container.querySelector('[data-part-id="base"] button')?.getAttribute("aria-expanded")).toBe("true");
  await act(async () => container.querySelector<HTMLButtonElement>('[data-part-id="cmux"] button')!.click());
  expect(container.querySelector('[data-part-id="base"] button')?.getAttribute("aria-expanded")).toBe("false");
  expect(container.querySelector('[data-part-id="cmux"] button')?.getAttribute("aria-expanded")).toBe("true");
});

test("keeps effective rows read-only and saves a separate next-session project override", async () => {
  const container = installDom();
  const saved: { id: string; text: string; scope: ContextOverrideScope }[] = [];
  await renderViewer(container, (scope, text) => {
    saved.push({ id: "cmux", text, scope });
  });
  await act(async () => container.querySelector<HTMLButtonElement>('[data-part-id="cmux"] button')!.click());
  expect(container.querySelector('[data-part-id="cmux"] textarea')).toBeNull();
  const editor = container.querySelector<HTMLTextAreaElement>("[data-context-editor] textarea")!;
  await act(async () => {
    const select = container.querySelector<HTMLSelectElement>("[data-context-editor] select")!;
    select.value = "project";
    select.dispatchEvent(new dom!.window.Event("change", { bubbles: true }));
  });
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), "value")!.set!;
    set.call(editor, "Prefer concurrent reads.");
    editor.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () =>
    container.querySelector<HTMLButtonElement>("[data-context-editor] .acpmux-context-part__save")!.click(),
  );
  expect(saved).toEqual([{ id: "cmux", text: "Prefer concurrent reads.", scope: "project" }]);
  expect(container.textContent).toContain("Saved for the next session");
});

test("does not invent a provider total or raw text", async () => {
  const container = installDom();
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ContextViewer
        parts={[
          {
            ...parts[0]!,
            tokenCount: undefined,
            measurement: "unavailable",
            text: "",
            textAvailable: false,
          },
        ]}
      />,
    );
  });
  expect(container.querySelector(".acpmux-context-viewer__heading")?.textContent).toContain("Token count unavailable");
  await act(async () => container.querySelector<HTMLButtonElement>('[data-part-id="base"] button')!.click());
  expect(container.textContent).toContain("Text is not exposed by this provider.");
});

test("edits and resets a preset prompt without changing the guidance part", async () => {
  const container = installDom();
  const calls: unknown[] = [];
  await act(async () => {
    root = createRoot(container);
    root.render(
      <ContextViewer
        parts={parts}
        settings={{
          user: "guidance user",
          project: null,
          parts: {
            "cmux-system-prompt": {
              label: "Preset system prompt",
              user: "preset user",
              project: null,
              defaultText: "preset default",
            },
          },
        }}
        onSaveOverride={(scope, text, partId) => {
          calls.push(["save", scope, text, partId]);
        }}
        onResetOverride={(scope, partId) => {
          calls.push(["reset", scope, partId]);
        }}
      />,
    );
  });
  await act(async () => {
    const select = container.querySelector<HTMLSelectElement>('select[aria-label="Part"]')!;
    select.value = "cmux-system-prompt";
    select.dispatchEvent(new dom!.window.Event("change", { bubbles: true }));
  });
  const editor = container.querySelector<HTMLTextAreaElement>("[data-context-editor] textarea")!;
  expect(editor.value).toBe("preset user");
  await act(async () => {
    const set = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(editor), "value")!.set!;
    set.call(editor, "new preset prompt");
    editor.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-context-part__save")!.click());
  await act(async () => container.querySelector<HTMLButtonElement>(".acpmux-context-part__reset")!.click());
  expect(calls).toEqual([
    ["save", "user", "new preset prompt", "cmux-system-prompt"],
    ["reset", "user", "cmux-system-prompt"],
  ]);
});
