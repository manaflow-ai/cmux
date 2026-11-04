import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ContextViewer, type ContextPart, type ContextOverrideScope } from "./ContextViewer";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
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
  { id: "base", label: "Harness base", source: "Claude Code", text: "Read first and work concurrently.", tokenCount: 7 },
  { id: "cmux", label: "cmux guidance", source: "cmux", text: "Use parallel tool calls.", tokenCount: 5, editable: true, scope: "user" },
];

async function renderViewer(container: HTMLElement, onSaveOverride?: (part: ContextPart, text: string, scope: ContextOverrideScope) => void | Promise<void>) {
  await act(async () => {
    root = createRoot(container);
    root.render(<ContextViewer parts={parts} harness="Claude" onSaveOverride={onSaveOverride} />);
  });
}

test("labels each effective part and token total, expanding exact text", async () => {
  const container = installDom();
  await renderViewer(container);
  expect(container.querySelector(".acpmux-context-viewer__heading")?.textContent).toContain("12 tokens");
  expect(container.querySelectorAll("[data-part-id]")).toHaveLength(2);
  expect(container.textContent).toContain("Claude Code · 7 tokens");
  expect(container.textContent).not.toContain("Read first and work concurrently.");
  await act(async () => container.querySelector<HTMLButtonElement>('[data-part-id="base"] button')!.click());
  expect(container.textContent).toContain("Read first and work concurrently.");
  expect(container.querySelector('[data-part-id="base"] button')?.getAttribute("aria-expanded")).toBe("true");
});

test("saves an editable cmux part with the selected project scope", async () => {
  const container = installDom();
  const saved: { id: string; text: string; scope: ContextOverrideScope }[] = [];
  await renderViewer(container, (part, text, scope) => saved.push({ id: part.id, text, scope }));
  await act(async () => container.querySelector<HTMLButtonElement>('[data-part-id="cmux"] button')!.click());
  const editor = container.querySelector<HTMLTextAreaElement>('[data-part-id="cmux"] textarea')!;
  await act(async () => {
    editor.value = "Prefer concurrent reads.";
    editor.dispatchEvent(new dom!.window.Event("input", { bubbles: true }));
  });
  await act(async () => {
    const select = container.querySelector<HTMLSelectElement>('[data-part-id="cmux"] select')!;
    select.value = "project";
    select.dispatchEvent(new dom!.window.Event("change", { bubbles: true }));
  });
  await act(async () => container.querySelector<HTMLButtonElement>('[data-part-id="cmux"] .acpmux-context-part__save')!.click());
  expect(saved).toEqual([{ id: "cmux", text: "Prefer concurrent reads.", scope: "project" }]);
  expect(container.textContent).toContain("Saved for the next session");
});

