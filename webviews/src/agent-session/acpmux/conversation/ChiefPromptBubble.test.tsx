// l10n-allow-file: test fixture prompts, not shipped UI.
// A prompt the Chief sent a subagent says so, and a long task opens on its first lines with Show
// all (Lawrence 2026-10-19: every prompt shows, attributed, long Chief tasks collapsed).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { ChiefPromptBubble } from "./ChiefPromptBubble";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function render(text: string): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
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
  const host = dom.window.document.getElementById("root")!;
  act(() => {
    root = createRoot(host);
    root.render(<ChiefPromptBubble text={text} />);
  });
  return host;
}

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

test("a short Chief prompt shows whole, marked as from the Chief", () => {
  const host = render("Fix the prompt bubble");
  expect(host.querySelector(".cv-user__from")?.textContent).toBe("From the Chief");
  expect(host.querySelector(".cv-user__bubble")?.textContent).toBe("Fix the prompt bubble");
  expect(host.querySelector(".cv-user__bubble--collapsed")).toBeNull();
  expect(host.querySelector(".cv-user__expand")).toBeNull();
});

test("a long Chief task opens collapsed and Show all opens it", () => {
  const task = Array.from({ length: 20 }, (_, index) => `Step ${index + 1}: do the thing.`).join("\n");
  const host = render(task);
  const bubble = () => host.querySelector(".cv-user__bubble")!;
  const toggle = () => host.querySelector<HTMLButtonElement>(".cv-user__expand")!;
  expect(bubble().classList.contains("cv-user__bubble--collapsed")).toBe(true);
  // The whole text stays in the bubble (select and copy take all of it); only its height is clamped.
  expect(bubble().textContent).toBe(task);
  expect(toggle().textContent).toBe("Show all");
  expect(toggle().getAttribute("aria-expanded")).toBe("false");
  act(() => {
    toggle().dispatchEvent(new dom!.window.MouseEvent("click", { bubbles: true }));
  });
  expect(bubble().classList.contains("cv-user__bubble--collapsed")).toBe(false);
  expect(toggle().textContent).toBe("Show less");
  expect(toggle().getAttribute("aria-expanded")).toBe("true");
});
